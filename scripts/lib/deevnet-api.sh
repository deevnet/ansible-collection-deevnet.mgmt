# Shared by the operator's tenant scripts. Sourced, not run.
#
# The operator token is read from the running API container on the
# provisioning VM, over SSH, into the calling process only: it is never
# printed and never written to disk.

API_URL="${DEEVNET_API_ENDPOINT:-https://api.mobile.deevnet.net:8080}"
API_HOST="${DEEVNET_API_HOST:-a_autoprov@dv02prv001v01.mobile.deevnet.net}"
DOWNLOADS="${DEEVNET_DOWNLOADS:-https://downloads.mobile.deevnet.net:8443}"
# The site CA under its own name; a tenant saves it locally as site-ca.pem.
SITE_CA_URL="${DEEVNET_SITE_CA_URL:-$DOWNLOADS/deevnet-mobile-ca.pem}"
STATE_BUCKET="${DEEVNET_STATE_BUCKET:-tf-state}"
CA="${DEEVNET_API_CACERT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.openbao/site-ca.pem}"

die() { echo "$*" >&2; exit 2; }

check_name() {
  [[ "$1" =~ ^[a-z][a-z0-9]{0,7}$ ]] ||
    die "'$1' is not a tenant name: 1-8 lowercase letters or digits, starting with a letter"
  [[ -r "$CA" ]] || die "no site CA at $CA"
}

# Sets TOKEN. Callers unset it when they are done.
load_operator_token() {
  TOKEN="$(ssh -o BatchMode=yes "$API_HOST" \
    "sudo podman inspect deevnet-api --format '{{range .Config.Env}}{{println .}}{{end}}'" |
    sed -n 's/^DEEVNET_API_TOKEN=//p')"
  [[ -n "$TOKEN" ]] || die "could not read the operator token from deevnet-api on $API_HOST"
}

# api METHOD PATH OUTFILE [curl args...] -> prints the HTTP status.
# OUTFILE is where the body goes: /dev/null when it does not matter.
api() {
  local method="$1" path="$2" out="$3"; shift 3
  curl -sS --cacert "$CA" -X "$method" -H "Authorization: Bearer $TOKEN" \
    -o "$out" -w '%{http_code}' "$@" "$API_URL$path"
}
