#!/usr/bin/env bash
# Take a tenant out of service, or clean up after a tenant that removed itself.
#
#   tenant-removal.sh remove      NAME   workloads, then the tenant, then its state
#   tenant-removal.sh purge-state NAME   only the state (after the tenant's own destroy)
#
# Both ask for the name to be typed back; CONFIRM=NAME answers in advance.
#
# The API's delete leaves the tenant's Terraform state behind, and the state
# bucket keeps every version of it, so the purge removes the versions too
# (runbook: Tenant Removal). It runs `mc` inside the MinIO container, whose
# root credentials never leave it.
set -euo pipefail

. "$(dirname "$0")/lib/deevnet-api.sh"

cmd="${1:-}"; name="${2:-}"
[[ "$cmd" == remove || "$cmd" == purge-state ]] || die "usage: $0 remove NAME | purge-state NAME"
check_name "$name"

confirm() {
  local answer="${CONFIRM:-}"
  if [[ -z "$answer" ]]; then
    read -r -p "This cannot be undone. Type '$name' to go ahead: " answer
  fi
  [[ "$answer" == "$name" ]] || die "not confirmed; nothing was changed"
}

# Runs inside the MinIO container on the provisioning VM. Plain HTTP on the
# container's own loopback where the service proxy holds the certificate
# (ADR-0036), HTTPS where MinIO still serves TLS itself.
minio() {
  ssh -o BatchMode=yes "$API_HOST" "sudo podman exec minio sh -c '
    export MC_CONFIG_DIR=/tmp/mc-tenant-removal
    { mc alias set local http://127.0.0.1:9000 \"\$MINIO_ROOT_USER\" \"\$MINIO_ROOT_PASSWORD\" >/dev/null 2>&1 ||
      mc alias set local https://127.0.0.1:9000 \"\$MINIO_ROOT_USER\" \"\$MINIO_ROOT_PASSWORD\" --insecure >/dev/null; } &&
    $1
    rc=\$?; rm -rf /tmp/mc-tenant-removal; exit \$rc'"
}

state_versions() {
  minio "mc ls --insecure --recursive --versions local/$STATE_BUCKET/tenants/$name/ | wc -l" | tr -d ' '
}

purge_state() {
  minio "mc rm --insecure --recursive --force --versions local/$STATE_BUCKET/tenants/$name/ >/dev/null"
  local left; left="$(state_versions)"
  [[ "$left" == 0 ]] || die "state purge left $left versions under $STATE_BUCKET/tenants/$name/"
  echo "state purged: $STATE_BUCKET/tenants/$name/ is empty"
}

load_operator_token
body="$(mktemp)"; trap 'rm -f "$body"' EXIT
code=$(api GET "/v1/tenants/$name" "$body")

if [[ "$cmd" == purge-state ]]; then
  # A live tenant still writes there: purging under it would lose its state.
  [[ "$code" == 404 ]] || die "$name is still a tenant (HTTP $code). Remove the tenant first: make remove-tenant NAME=$name"
  unset TOKEN
  versions="$(state_versions)"
  if [[ "$versions" == 0 ]]; then echo "nothing to purge: $STATE_BUCKET/tenants/$name/ is empty"; exit 0; fi
  echo "$STATE_BUCKET/tenants/$name/ holds $versions object versions: the state of a tenant that no longer exists."
  confirm
  purge_state
  exit 0
fi

case "$code" in
  200) ;;
  404) die "$name is not a tenant. Leftover state only? make purge-tenant-state NAME=$name" ;;
  *)   die "HTTP $code reading tenant $name" ;;
esac
index=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('index','?'))" "$body")

code=$(api GET "/v1/tenants/$name/workloads" "$body")
[[ "$code" == 200 ]] || die "HTTP $code listing $name's workloads"
workloads=$(python3 -c "import json,sys; print(' '.join(w['name'] for w in json.load(open(sys.argv[1])).get('workloads') or []))" "$body")

echo "Removing tenant $name (index $index):"
echo "  workloads:  ${workloads:-none}"
echo "  then its network, DNS zones, broker accounts, Wi-Fi keys, log tokens and Grafana login,"
echo "  and its Terraform state in $STATE_BUCKET/tenants/$name/, every version."
confirm

for w in $workloads; do
  code=$(api DELETE "/v1/tenants/$name/workloads/$w" /dev/null)
  [[ "$code" == 2?? ]] || die "HTTP $code deleting workload $w; the tenant is untouched"
  echo "deleted workload $w"
done

code=$(api DELETE "/v1/tenants/$name" "$body")
unset TOKEN
case "$code" in
  2??) echo "deleted tenant $name" ;;
  409) die "HTTP 409: $(cat "$body"). The registry still holds something for $name." ;;
  502) die "HTTP 502: a backend step failed ($(cat "$body")). $name is left 'deleting'; running this again resumes." ;;
  *)   die "HTTP $code deleting tenant $name: $(cat "$body")" ;;
esac

purge_state
echo "Still there, by design or for now (runbook: Tenant Removal): log lines until retention,"
echo "the renamed Grafana organization, and audit entries."
