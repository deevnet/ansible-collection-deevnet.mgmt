#!/usr/bin/env bash
# The ONLINE half of the offline CA ceremony (runbook: Root of Trust > Issuing CA).
#
#   deevnet-pki-transfer.sh prepare MEDIA --site mobile --ca substrate|tenant-device --csr FILE [--with-tools]
#   deevnet-pki-transfer.sh accept  MEDIA --csr FILE [--out DIR]
#
# prepare  cleans MEDIA/deevnet-transfer, checks the issuing CA's signing request
#          (signature, subject, key), and writes it to MEDIA with the public
#          certificates, under a manifest of SHA-256 hashes: data only, for the
#          pi-pki ceremony image, which carries the signing tool and profile.
#          --with-tools adds both, manifested, for the fallback route (a live
#          USB that does not). Fails if the transfer media carries any
#          private key, before and after.
# accept   checks what came back: the return manifest, that the certificate is
#          for the original request's key and subject, and that it chains to the
#          Deevnet Root CA through the Site CA - using the INVENTORY's copies of
#          both, never the media's. Only then copies it to --out.
#
# The transfer media crosses between the online and offline machines. The media
# holding the Root CA's and Site CA's keys never does, and never meets this
# script. Needs bash, openssl and coreutils.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKI_DIR="${DEEVNET_PKI_DIR:-$(cd "$HERE/../../.." && pwd)/ansible-inventory-deevnet/pki}"
ROOT_CERT="$PKI_DIR/deevnet-root-ca.pem"

die() { echo "deevnet-pki-transfer.sh: $*" >&2; exit 1; }
say() { echo "  $*"; }

# Any private key anywhere on the media - by name or by content - stops the run.
refuse_private_keys() {
  local media="$1" hits
  hits="$(find "$media" -type f \( -iname '*.key' -o -iname '*.p12' -o -iname '*.pfx' -o -iname '*.jks' \) 2>/dev/null || true)"
  hits+="$(grep -rlIE -- '-----BEGIN ([A-Z]+ )?PRIVATE KEY-----' "$media" 2>/dev/null || true)"
  [[ -z "$hits" ]] || die "private-key material on the transfer media - remove it and start again:
$hits"
}

title() { echo "${1^}"; }                       # mobile -> Mobile
ca_cn() {                                       # site, ca -> expected CN
  case "$2" in
    substrate)     echo "Deevnet $(title "$1") Substrate CA" ;;
    tenant-device) echo "Deevnet $(title "$1") Tenant Device CA" ;;
    *) die "--ca must be substrate or tenant-device" ;;
  esac
}
subject() { openssl "$1" -in "$2" -noout -subject -nameopt RFC2253 | sed 's/^subject=//'; }
pubkey_hash() { openssl "$1" -in "$2" -noout -pubkey | openssl pkey -pubin -outform DER | sha256sum | cut -d' ' -f1; }

cmd="${1:-}"; media="${2:-}"; shift 2 || true
site=""; ca=""; csr=""; out=""; with_tools=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --site) site="$2"; shift 2 ;;
    --ca)   ca="$2"; shift 2 ;;
    --csr)  csr="$2"; shift 2 ;;
    --out)  out="$2"; shift 2 ;;
    --with-tools) with_tools=1; shift ;;
    *) die "unknown option $1" ;;
  esac
done
[[ "$cmd" == prepare || "$cmd" == accept ]] || die "usage: $0 prepare|accept MEDIA ... (see the header)"
[[ -d "$media" ]] || die "no transfer media mounted at '$media'"
[[ -f "$csr" ]] || die "--csr: no such file '$csr'"
T="$media/deevnet-transfer"

if [[ "$cmd" == prepare ]]; then
  [[ -n "$site" && -n "$ca" ]] || die "prepare needs --site and --ca"
  site_cert="$PKI_DIR/$site/deevnet-$site-site-ca.pem"
  [[ -f "$ROOT_CERT" ]] || die "no Deevnet Root CA at $ROOT_CERT"
  [[ -f "$site_cert" ]] || die "no Site CA certificate at $site_cert"
  want="CN=$(ca_cn "$site" "$ca"),OU=$(title "$site") Site,O=Deevnet"

  echo "Checking the request"
  openssl req -in "$csr" -noout -verify >/dev/null 2>&1 || die "the request's signature does not verify"
  got="$(subject req "$csr")"
  [[ "$got" == "$want" ]] || die "the request names '$got', not '$want'"
  bits="$(openssl req -in "$csr" -noout -text | sed -n 's/.*Public-Key: (\([0-9]*\) bit).*/\1/p')"
  [[ "${bits:-0}" -ge 3072 ]] || die "an issuing CA's key must be RSA 3072 or larger (standards/certificates); this one is ${bits:-unknown} bit"
  say "subject $got, RSA $bits"

  echo "Preparing $T"
  refuse_private_keys "$media"
  rm -rf "$T"; mkdir -p "$T/to-offline"
  name="deevnet-$site-$ca-ca"
  cp "$csr" "$T/to-offline/$name.csr"
  cp "$ROOT_CERT" "$site_cert" "$T/to-offline/"
  if [[ "$with_tools" == 1 ]]; then cp "$HERE/deevnet-pki.cnf" "$HERE/deevnet-pki-sign.sh" "$T/to-offline/"; fi
  ( cd "$T/to-offline"
    { echo "# deevnet-transfer to-offline"
      echo "# created $(date -u +%FT%TZ) on $(hostname)"
      echo "# site $site, issuing CA $ca"
      echo "# request subject $got"
      echo "# request public key sha256 $(pubkey_hash req "$name.csr")"
      sha256sum -- *
    } > ../.MANIFEST.tmp && mv ../.MANIFEST.tmp MANIFEST )   # written outside, so it never lists itself
  refuse_private_keys "$media"
  sync
  echo "Ready. Write this on the paper record and check it on the offline machine:"
  say "manifest sha256 $(sha256sum "$T/to-offline/MANIFEST" | cut -d' ' -f1)"
  say "request public key sha256 $(pubkey_hash req "$csr")"
  exit 0
fi

# --- accept -------------------------------------------------------------------
R="$T/to-online"
[[ -f "$R/MANIFEST" ]] || die "nothing returned: no $R/MANIFEST"
echo "Checking what came back"
refuse_private_keys "$media"
( cd "$R" && grep -v '^#' MANIFEST | sha256sum --quiet -c - ) || die "the return manifest does not match its files"
cert="$(find "$R" -maxdepth 1 -name 'deevnet-*-ca.pem' | head -1)"
[[ -n "$cert" ]] || die "no certificate in $R"
name="$(basename "$cert" .pem)"; site="$(echo "$name" | cut -d- -f2)"
site_cert="$PKI_DIR/$site/deevnet-$site-site-ca.pem"
[[ -f "$ROOT_CERT" && -f "$site_cert" ]] || die "the inventory has no Root CA or $site Site CA to check against"

[[ "$(pubkey_hash x509 "$cert")" == "$(pubkey_hash req "$csr")" ]] || die "the certificate is not for the original request's key"
[[ "$(subject x509 "$cert")" == "$(subject req "$csr")" ]] || die "the certificate's subject differs from the request's"
openssl verify -no-CApath -no-CAstore -CAfile "$ROOT_CERT" -untrusted "$site_cert" "$cert" >/dev/null 2>&1 \
  || die "the certificate does not chain to the Deevnet Root CA through the $site Site CA (inventory copies)"
openssl x509 -in "$cert" -noout -ext basicConstraints | grep -q 'CA:TRUE, pathlen:0' \
  || die "the certificate is not an issuing CA (CA:TRUE, pathlen:0)"
say "subject $(subject x509 "$cert")"
say "issuer  $(openssl x509 -in "$cert" -noout -issuer -nameopt RFC2253 | sed 's/^issuer=//')"
say "valid   $(openssl x509 -in "$cert" -noout -enddate | sed 's/notAfter=/to /')"
say "$(openssl x509 -in "$cert" -noout -fingerprint -sha256) - compare with the paper record"

if [[ -n "$out" ]]; then
  mkdir -p "$out"; cp "$cert" "$out/"
  echo "Accepted: $out/$name.pem"
else
  echo "Accepted. Re-run with --out DIR to copy it for installation."
fi
