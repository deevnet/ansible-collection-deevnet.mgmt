#!/usr/bin/env bash
# Re-ensure tenants through the Deevnet API: everything the API owns for the
# tenant is checked and repaired, Grafana data sources included.
#
#   tenant-reconcile.sh TENANT...
#   tenant-reconcile.sh --all
#
# Needed when something the API writes INTO a tenant's resources changes under
# it - for example the CA its Grafana data sources carry to reach the log store
# (CHG-0031) - since a tenant's own apply would only repair it the next time
# that tenant runs one.
set -euo pipefail

. "$(dirname "$0")/lib/deevnet-api.sh"

[[ $# -gt 0 ]] || die "usage: $0 TENANT... | --all"
[[ -r "$CA" ]] || die "no site CA at $CA"

load_operator_token
body="$(mktemp)"; trap 'rm -f "$body"; unset TOKEN' EXIT; chmod 600 "$body"

if [[ "$1" == --all ]]; then
  code=$(api GET /v1/tenants "$body")
  [[ "$code" == 200 ]] || die "HTTP $code listing tenants"
  mapfile -t names < <(python3 -c "
import json,sys; d=json.load(open(sys.argv[1]))
for t in (d.get('tenants') if isinstance(d, dict) else d) or []: print(t['name'])" "$body")
else
  names=("$@")
fi

failed=0
for name in "${names[@]}"; do
  check_name "$name"
  code=$(api POST "/v1/tenants/$name/reconcile" "$body")
  if [[ "$code" == 200 ]]; then
    echo "reconciled $name"
  else
    # An error body names the failed step and carries no secret.
    echo "HTTP $code reconciling $name: $(head -c 400 "$body")" >&2
    failed=1
  fi
done
exit "$failed"
