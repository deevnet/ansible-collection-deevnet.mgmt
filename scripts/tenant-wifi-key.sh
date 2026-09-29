#!/usr/bin/env bash
# Rotate a tenant's Wi-Fi key: the same key, a new password.
#
#   tenant-wifi-key.sh rotate TENANT [KEY]     KEY defaults to 'admission'
#
# For a password that was lost or may have leaked, or just on a schedule.
# Reads never return a password, so a lost one is replaced, not recovered.
# The key keeps its name, trust class and MAC binding; the old password stops
# working on every device that uses it. The new one goes to ~/TENANT-wifi-KEY.txt (mode 0600), to hand over.
#
# 'admission' is the DVNTM-TD key the tenant was admitted with, which the
# tenant's Terraform does not declare. A key the tenant declares is the
# tenant's to rotate (terraform apply -replace=...): rotated here, its state
# would go on holding the old password.
set -euo pipefail

. "$(dirname "$0")/lib/deevnet-api.sh"

cmd="${1:-}"; name="${2:-}"; key="${3:-admission}"
[[ "$cmd" == rotate ]] || die "usage: $0 rotate TENANT [KEY]"
check_name "$name"
[[ "$key" =~ ^[a-z][a-z0-9-]{0,19}$ ]] || die "'$key' is not a key name"

load_operator_token
body="$(mktemp)"; trap 'rm -f "$body"' EXIT; chmod 600 "$body"

code=$(api GET "/v1/tenants/$name/wifi-keys/$key" "$body")
case "$code" in
  200) ;;
  404) [[ "$(api GET "/v1/tenants/$name" /dev/null)" == 200 ]] || die "$name is not a tenant"
       api GET "/v1/tenants/$name/wifi-keys" "$body" >/dev/null || true
       keys=$(python3 -c "import json,sys; print(', '.join(k['name'] for k in json.load(open(sys.argv[1])).get('wifi_keys') or []) or 'none')" "$body" 2>/dev/null || echo '?')
       die "$name has no Wi-Fi key '$key' (its keys: $keys)" ;;
  *)   die "HTTP $code reading $name's Wi-Fi key '$key'" ;;
esac
read -r class mac ssid < <(python3 -c "
import json,sys; k=json.load(open(sys.argv[1]))
print(k['trust_class'], k.get('mac') or '-', k.get('ssid') or '-')" "$body")

bound=""; [[ "$mac" == - ]] || bound=", bound to $mac"
echo "Rotating $name's Wi-Fi key '$key' ($class on $ssid$bound):"
echo "  its current password stops working on every device that uses it."
[[ "$key" == admission ]] ||
  echo "  NOTE: if $name's Terraform declares '$key', its state keeps the old password;"
[[ "$key" == admission ]] ||
  echo "  a declared key is the tenant's to rotate, with terraform apply -replace."
answer="${CONFIRM:-}"
[[ -n "$answer" ]] || read -r -p "Type '$name' to go ahead: " answer
[[ "$answer" == "$name" ]] || die "not confirmed; nothing was changed"

code=$(api DELETE "/v1/tenants/$name/wifi-keys/$key" /dev/null)
[[ "$code" == 2?? ]] || die "HTTP $code deleting the old key; nothing was changed"

req=$(python3 -c "
import json,sys; d={'name':sys.argv[1],'trust_class':sys.argv[2]}
if sys.argv[3] != '-': d['mac']=sys.argv[3]
print(json.dumps(d))" "$key" "$class" "$mac")
code=$(api POST "/v1/tenants/$name/wifi-keys" "$body" -H 'Content-Type: application/json' -d "$req")
unset TOKEN
if [[ "$code" != 201 ]]; then
  echo "HTTP $code creating the new key: $(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('error',''))" "$body" 2>/dev/null)" >&2
  die "The old key is deleted and the new one is not in service. Run this again to finish."
fi

out="$HOME/$name-wifi-$key.txt"
umask 077
python3 - "$body" "$out" "$name" <<'EOF'
import json, sys
body, out, tenant = sys.argv[1:]
k = json.load(open(body))
lines = [
    f"Deevnet tenant Wi-Fi key: {tenant} / {k['name']}",
    "",
    "SECRET: this holds a Wi-Fi password. Hand it over on a channel you would trust",
    "with a password, then delete it.",
    "",
    f"Wi-Fi network      {k.get('ssid', '')}",
    f"Wi-Fi password     {k['psk']}",
]
if k.get("mac"):
    lines.append(f"  works only for   {k['mac']}")
lines += [
    "",
    "The previous password for this key no longer works. Forget the network on",
    "each device and join again with the password above.",
]
with open(out, "w") as f:
    f.write("\n".join(lines) + "\n")
EOF
echo "rotated $name's key '$key': new password in $out (mode 0600)"
