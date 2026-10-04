#!/usr/bin/env bash
# The OFFLINE step of the CA ceremony (runbook: Root of Trust > Issuing CA).
# Runs on the offline machine. On the pi-pki ceremony image it is installed as
# /usr/local/bin/deevnet-pki-sign.sh with its profile, and the transfer media
# carries data only:
#
#   deevnet-pki-sign.sh /path/to/transfer --site-key /path/to/key-media/deevnet-mobile-site-ca.key
#
# On the fallback route (a Fedora live USB) both came on the transfer media
# (deevnet-pki-transfer.sh prepare --with-tools), under its manifest:
#
#   bash /path/to/transfer/deevnet-transfer/to-offline/deevnet-pki-sign.sh /path/to/transfer --site-key ...
#
# It checks the manifest and that the transfer media holds no private key,
# shows the request and what will be signed, asks the operator to confirm by
# typing the CA's name, signs with the Site CA, checks the result, and writes
# ONLY the certificate and a return manifest to the transfer media. The Site
# CA's key is read from the key media and never written anywhere.
set -euo pipefail

die() { echo "deevnet-pki-sign.sh: $*" >&2; exit 1; }
say() { echo "  $*"; }
refuse_private_keys() {
  local media="$1" hits
  hits="$(find "$media" -type f \( -iname '*.key' -o -iname '*.p12' -o -iname '*.pfx' -o -iname '*.jks' \) 2>/dev/null || true)"
  hits+="$(grep -rlIE -- '-----BEGIN ([A-Z]+ )?PRIVATE KEY-----' "$media" 2>/dev/null || true)"
  [[ -z "$hits" ]] || die "private-key material on the transfer media - stop, and remove it:
$hits"
}
pubkey_hash() { openssl "$1" -in "$2" -noout -pubkey | openssl pkey -pubin -outform DER | sha256sum | cut -d' ' -f1; }

media="${1:-}"; shift || true
site_key=""; days=1826; profile=""
# The earliest date this tool will sign on: an offline machine with no clock
# boots with a wrong date, and a certificate's validity starts from it. The
# ceremony image's build date, when there is one, is a later floor.
DATE_FLOOR="2026-10-03"
RELEASE="${DEEVNET_PKI_RELEASE:-/etc/deevnet-pki-release}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --site-key) site_key="$2"; shift 2 ;;
    --profile)  profile="$2"; shift 2 ;;
    *) die "unknown option $1" ;;
  esac
done
T="$media/deevnet-transfer"; IN="$T/to-offline"; OUT="$T/to-online"
[[ -f "$IN/MANIFEST" ]] || die "no $IN/MANIFEST - is the transfer media mounted at '$media'?"
[[ -f "$site_key" ]] || die "--site-key: no such file '$site_key'"

# The Site CA's key must come from its own media, never from the transfer media.
case "$(realpath "$site_key")/" in "$(realpath "$media")"/*) die "the Site CA's key is on the transfer media - it must stay on its key media" ;; esac
if [[ "$(stat -c %d "$site_key")" == "$(stat -c %d "$media")" ]]; then
  die "the Site CA's key is on the same filesystem as the transfer media - use the key media"
fi
if ip -brief address 2>/dev/null | grep -v '^lo ' | grep -q UP; then
  die "a network interface is up - this machine must be offline (nmcli networking off)"
fi

# The profile: the image's, unless given; on the fallback route, the one that
# came on the transfer media under the manifest.
if [[ -z "$profile" ]]; then
  if [[ -f /usr/local/share/deevnet-pki/deevnet-pki.cnf ]]; then profile=/usr/local/share/deevnet-pki/deevnet-pki.cnf
  else profile="$IN/deevnet-pki.cnf"; fi
fi
[[ -f "$profile" ]] || die "no signing profile at $profile"

echo "0. The clock"
floor="$DATE_FLOOR"
if [[ -f "$RELEASE" ]]; then
  built="$(sed -n 's/^built=//p' "$RELEASE")"; [[ -n "$built" && "$built" > "$floor" ]] && floor="$built"
fi
today="$(date -u +%F)"
[[ ! "$today" < "$floor" ]] || die "the clock says $today, before $floor - set it first: sudo date -u -s 'YYYY-MM-DD HH:MM'"
say "now $(date -u '+%F %H:%M') UTC - the certificate's validity starts here"
read -r -p "Is that today's date and time? (yes/no): " ok
[[ "$ok" == yes ]] || die "set the clock first: sudo date -u -s 'YYYY-MM-DD HH:MM'"
echo

echo "1. Checking the transfer media"
refuse_private_keys "$media"
( cd "$IN" && grep -v '^#' MANIFEST | sha256sum --quiet -c - ) || die "the manifest does not match its files - do not sign"
say "manifest sha256 $(sha256sum "$IN/MANIFEST" | cut -d' ' -f1)  (compare with the paper record)"
grep '^#' "$IN/MANIFEST" | sed 's/^# /  /'

csr="$(find "$IN" -maxdepth 1 -name 'deevnet-*-ca.csr' | head -1)"
[[ -n "$csr" ]] || die "no request in $IN"
name="$(basename "$csr" .csr)"; site="$(echo "$name" | cut -d- -f2)"
site_cert="$IN/deevnet-$site-site-ca.pem"; root_cert="$IN/deevnet-root-ca.pem"
openssl verify -no-CApath -no-CAstore -CAfile "$root_cert" "$site_cert" >/dev/null || die "the Site CA certificate does not chain to the root"
# Asked once, used for the key check and the signature, and gone at exit.
if [[ -z "${DEEVNET_SITE_KEY_PASS:-}" ]]; then
  read -r -s -p "Passphrase for $(basename "$site_key"): " DEEVNET_SITE_KEY_PASS; echo
fi
export DEEVNET_SITE_KEY_PASS
[[ "$(openssl x509 -in "$site_cert" -noout -pubkey | openssl pkey -pubin -outform DER | sha256sum)" == \
   "$(openssl pkey -in "$site_key" -passin env:DEEVNET_SITE_KEY_PASS -pubout -outform DER | sha256sum)" ]] \
  || die "the key given is not the $site Site CA's key"
openssl req -in "$csr" -noout -verify >/dev/null 2>&1 || die "the request's signature does not verify"

subj="$(openssl req -in "$csr" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')"
cn="$(echo "$subj" | sed -n 's/^CN=\([^,]*\),.*/\1/p')"
echo
echo "2. What will be signed"
say "subject     $subj"
say "public key  $(openssl req -in "$csr" -noout -text | grep -m1 -o "Public-Key: ([0-9]* bit)")  sha256 $(pubkey_hash req "$csr")"
say "issued by   $(openssl x509 -in "$site_cert" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')"
say "for         $days days, CA:TRUE pathlen:0, keyCertSign cRLSign (v3_issuing in $profile)"
say "requested extensions are ignored; only the profile's are applied"
echo
read -r -p "Type the CA's name exactly to sign it ($cn): " typed
[[ "$typed" == "$cn" ]] || die "not confirmed - nothing was signed"

echo
echo "3. Signing"
work="$(mktemp -d /dev/shm/deevnet-sign.XXXXXX)"; trap 'rm -rf "$work"; unset DEEVNET_SITE_KEY_PASS' EXIT
openssl x509 -req -in "$csr" -CA "$site_cert" -CAkey "$site_key" -passin env:DEEVNET_SITE_KEY_PASS \
  -extfile "$profile" -extensions v3_issuing -days "$days" -sha256 \
  -set_serial "0x$(openssl rand -hex 16)" -out "$work/$name.pem"

echo "4. Checking the certificate"
openssl verify -no-CApath -no-CAstore -CAfile "$root_cert" -untrusted "$site_cert" "$work/$name.pem" >/dev/null || die "the new certificate does not chain - nothing written"
[[ "$(pubkey_hash x509 "$work/$name.pem")" == "$(pubkey_hash req "$csr")" ]] || die "the certificate is not for the request's key"
openssl x509 -in "$work/$name.pem" -noout -ext basicConstraints | grep -q 'CA:TRUE, pathlen:0' || die "pathlen is not 0"
fp="$(openssl x509 -in "$work/$name.pem" -noout -fingerprint -sha256 | sed 's/.*=//')"
say "chains to the Deevnet Root CA; pathlen 0; key matches the request"

echo "5. Writing the certificate back"
rm -rf "$OUT"; mkdir -p "$OUT"
cp "$work/$name.pem" "$OUT/"
( cd "$OUT"
  { echo "# deevnet-transfer to-online"
    echo "# signed $(date -u +%FT%TZ) by $(openssl x509 -in "$site_cert" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')"
    echo "# certificate sha256 fingerprint $fp"
    echo "# request public key sha256 $(pubkey_hash req "$csr")"
    sha256sum -- *
  } > ../.MANIFEST.tmp && mv ../.MANIFEST.tmp MANIFEST )   # written outside, so it never lists itself
refuse_private_keys "$media"
sync
echo
echo "Done. Write on the paper record: $name, $(date -u +%F), fingerprint"
say "$fp"
