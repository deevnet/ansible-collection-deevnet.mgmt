#!/usr/bin/env bash
# Reissue a tenant's state-store secret (CHG-0060, 2026-10 review T2).
#
#   tenant-state-secret.sh reissue TENANT
#
# For a tenant that has lost the keys to its own state: they are kept inside
# that state, so without a copy there is no other way back in. The API mints a
# new secret and sets it on the store; the old one stops working. The stored
# secret is never handed out. The new one goes to ~/TENANT-state-secret.txt
# (mode 0600), to hand over.
#
# The tenant's Terraform state still holds the old secret afterwards. A
# restore over the registry keeps the reissued one and hands it back, so state
# takes it up (API v0.22.5, provider v0.10.2; ADR-0015 §5).
set -euo pipefail

. "$(dirname "$0")/lib/deevnet-api.sh"

cmd="${1:-}"; name="${2:-}"
[[ "$cmd" == reissue ]] || die "usage: $0 reissue TENANT"
check_name "$name"

load_operator_token
body="$(mktemp)"; trap 'rm -f "$body"; unset TOKEN' EXIT; chmod 600 "$body"

code=$(api GET "/v1/tenants/$name" /dev/null)
case "$code" in
  200) ;;
  404) die "$name is not a tenant" ;;
  *)   die "HTTP $code reading $name" ;;
esac

echo "Reissuing $name's state-store secret:"
echo "  the current secret stops working for everyone who holds it, including CI."
answer="${CONFIRM:-}"
[[ -n "$answer" ]] || read -r -p "Type '$name' to go ahead: " answer
[[ "$answer" == "$name" ]] || die "not confirmed; nothing was changed"

code=$(api POST "/v1/tenants/$name/state-secret" "$body")
unset TOKEN
if [[ "$code" != 200 ]]; then
  # An error body names the failed step and carries no secret.
  echo "HTTP $code reissuing: $(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('error',''))" "$body" 2>/dev/null)" >&2
  [[ "$code" == 502 ]] && die "No secret was issued, and the store may still hold the old one. Run this again."
  die "nothing was issued"
fi

out="$HOME/$name-state-secret.txt"
umask 077
python3 - "$body" "$out" <<'EOF'
import json, sys
body, out = sys.argv[1:]
d = json.load(open(body))
s = d["state"]
lines = [
    f"Deevnet tenant state-store secret: {d['name']}",
    "",
    "SECRET: this holds the key to your Terraform state. Hand it over on a channel",
    "you would trust with a password, then delete it.",
    "",
    f"Endpoint           {s['endpoint']}",
    f"Bucket and prefix  {s['bucket']}/{s['key_prefix']}",
    "",
    "Your .backend.env, beside a clone of your tenant repository:",
    "",
    f"AWS_ACCESS_KEY_ID={s['access_key']}",
    f"AWS_SECRET_ACCESS_KEY={s['secret_key']}",
    "",
    "The previous secret no longer works. Replace it wherever you kept it.",
    "Your state still holds the previous secret: don't restore your tenant from it.",
]
with open(out, "w") as f:
    f.write("\n".join(lines) + "\n")
EOF
echo "reissued $name's state secret: handover in $out (mode 0600)"
