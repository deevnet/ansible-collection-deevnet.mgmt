#!/usr/bin/env bash
# Admit a tenant name, or revoke an admission that was never used.
#
#   tenant-admission.sh admit   NAME [MAC]
#   tenant-admission.sh unadmit NAME
#
# The operator token is read from the running API container on the
# provisioning VM, over SSH, into this process only: it is never printed and
# never written to disk. An admission's secrets go to ~/NAME-admission.txt
# (mode 0600), written for the person handing them over, not for a program.
set -euo pipefail

. "$(dirname "$0")/lib/deevnet-api.sh"

cmd="${1:-}"; name="${2:-}"; mac="${3:-}"
[[ "$cmd" == admit || "$cmd" == unadmit ]] || die "usage: $0 admit NAME [MAC] | unadmit NAME"
check_name "$name"
[[ -z "$mac" || "$mac" =~ ^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$ ]] ||
  die "'$mac' is not a MAC address (AA-BB-CC-00-11-22)"
out="$HOME/$name-admission.txt"

load_operator_token

if [[ "$cmd" == unadmit ]]; then
  code=$(api DELETE "/v1/admissions/$name" /dev/null)
  unset TOKEN
  case "$code" in
    2??) echo "revoked the admission for $name: its Wi-Fi key no longer works"
         rm -f "$out" ;;
    404) die "no pending admission for $name: never admitted, already spent, or already revoked" ;;
    *)   die "HTTP $code revoking the admission for $name" ;;
  esac
  exit 0
fi

# Admitting a name again issues a new Wi-Fi key and kills the one handed over
# before, so an existing file is a reason to stop and look.
if [[ -e "$out" && -z "${FORCE:-}" ]]; then
  die "$out already exists. Admitting $name again replaces the key handed over before;
rerun with FORCE=1 if that is what you want."
fi

body="{\"name\":\"$name\"${mac:+,\"mac\":\"$mac\"}}"
resp="$(mktemp)"; trap 'rm -f "$resp"' EXIT; chmod 600 "$resp"
code=$(api POST /v1/admissions "$resp" -H 'Content-Type: application/json' -d "$body")
unset TOKEN
if [[ "$code" != 201 ]]; then
  # An error body carries no secret.
  echo "HTTP $code admitting $name: $(cat "$resp")" >&2
  [[ "$code" == 409 ]] && echo "The name is already a tenant: it uses its own token, not a new admission." >&2
  exit 1
fi

fingerprint=$(openssl x509 -in "$CA" -noout -fingerprint -sha256 | cut -d= -f2)

umask 077
python3 - "$resp" "$out" "$API_URL" "$DOWNLOADS" "$fingerprint" <<'EOF'
import json, sys
resp, out, api, downloads, fingerprint = sys.argv[1:]
d = json.load(open(resp))
w = d.get("wifi") or {}
lines = [
    f"Deevnet tenant admission: {d['name']}",
    "",
    "SECRET: this holds a single-use enrollment token and a Wi-Fi password.",
    "Hand it over on a channel you would trust with a password, then delete it.",
    "",
    f"Enrollment token   {d['enrollment_token']}",
    f"  expires          {d['expires_at']}  (single use, bound to the name '{d['name']}')",
    f"API endpoint       {api}",
    f"Wi-Fi network      {w.get('ssid', '')}",
    f"Wi-Fi password     {w.get('psk', '')}",
]
if w.get("mac"):
    lines.append(f"  works only for   {w['mac']}")
lines += [
    f"Site CA            {downloads}/site-ca.pem",
    f"  SHA-256          {fingerprint}",
    "",
    "For the tenant:",
    f"  1. Join {w.get('ssid', 'the network')} with the password above.",
    "  2. Download site-ca.pem and check its SHA-256 fingerprint matches the one above.",
    "  3. export DEEVNET_API_TOKEN=<the enrollment token>, then make init && make apply.",
    "     The first apply spends the token and the Wi-Fi key becomes the tenant's own.",
]
with open(out, "w") as f:
    f.write("\n".join(lines) + "\n")
print(f"admitted {d['name']}: expires {d['expires_at']}, Wi-Fi {w.get('ssid', '')}"
      + (f" (bound to {w['mac']})" if w.get("mac") else ""))
EOF
echo "handover details: $out (mode 0600)"
