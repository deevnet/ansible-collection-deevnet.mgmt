#!/usr/bin/env bash
# A starter PKI of an owner's own (ADR-0041 §3): the tools a take-home Pi's
# owner uses to leave Deevnet with a PKI of their own. deevnet-kit pki init
# runs them; they can also be run by hand, and taken further.
#
#   deevnet-pki-owner.sh init    --org ORG [--domain D]... --out DIR [--keys DIR]
#       A new root on an encrypted USB stick, and an issuing CA in DIR, signed by it.
#   deevnet-pki-owner.sh issuing --org ORG [--domain D]... --out DIR [--keys DIR]
#       A new issuing CA in DIR from the root already on the stick: a new card,
#       or a card lost or stolen. Nothing a device trusts changes.
#   deevnet-pki-owner.sh leaf server --ca DIR --out DIR --name NAME... [--csr FILE] [--days N]
#   deevnet-pki-owner.sh leaf device --ca DIR --out DIR --name DEVICE  [--csr FILE] [--days N]
#       A certificate from the issuing CA in --ca: a server's, for the names and
#       addresses given, or a device's, for its name. With --csr it signs that
#       request's key; without, it makes a key in --out.
#
# Two tiers, where Deevnet has three: the root, on the stick and nowhere else,
# and one issuing CA, on the Pi. A lost card costs the issuing CA, never the
# root. The issuing CA may name only the owner's domains, .local, localhost,
# and private and loopback addresses (deevnet-pki-owner.cnf), so its key, taken
# with a card, cannot vouch for a public site.
#
# The stick is key media as deevnet-pki-media.sh makes it, LUKS2 and labelled
# owner-keys-primary: the script asks for it when it needs it, offers to
# format a new one (init only), and closes it at the end. --keys names one
# already open instead; it must be a mounted encrypted filesystem. The root
# key inside it is encrypted again with its own passphrase.
#
# Unlike Deevnet's ceremony (deevnet-pki-ceremony.sh), the machine may be
# online: this is the owner's Pi, and the root key is made in memory and
# written only to the stick.
set -euo pipefail

PROFILE="${DEEVNET_PKI_OWNER_PROFILE:-/usr/local/share/deevnet-pki/deevnet-pki-owner.cnf}"
MEDIA="${DEEVNET_PKI_MEDIA:-deevnet-pki-media.sh}"
export DEEVNET_PKI_KEYS_PREFIX=owner-keys
export DEEVNET_PKI_KEYS_MNT="${DEEVNET_PKI_OWNER_KEYS_MNT:-/mnt/owner-keys}"
DATE_FLOOR="2026-11-01"

ROOT_DAYS=7305     # 20 years
ISSUING_DAYS=1826  # 5 years
LEAF_DAYS=825      # the longest server certificate Apple platforms accept

ROOT_KEY=owner-root-ca.key
ROOT_CERT=owner-root-ca.pem
ISSUING_KEY=owner-issuing-ca.key
ISSUING_CERT=owner-issuing-ca.pem

die() { echo "deevnet-pki-owner.sh: $*" >&2; exit 1; }
say() { echo "  $*"; }
fingerprint() { openssl x509 -in "$1" -noout -fingerprint -sha256 | sed 's/^.*=//'; }
pubkey_hash() {   # x509|req FILE, or key FILE
  if [[ "$1" == key ]]; then openssl pkey -in "$2" -pubout -outform DER
  else openssl "$1" -in "$2" -noout -pubkey | openssl pkey -pubin -outform DER; fi | sha256sum | cut -d' ' -f1
}

# Every variable the profile names is set on every call: OpenSSL refuses the
# whole file if one is not.
export PKI_OWNER_ORG="unset" PKI_OWNER_CN="unset" PKI_OWNER_PERMITTED="permitted;DNS:invalid" PKI_OWNER_SAN="DNS:invalid"

# The root key's passphrase: asked for by openssl unless PKI_OWNER_ROOT_PASS is
# set (tests, or a caller that asked for it already).
pass_out() { [[ -n "${PKI_OWNER_ROOT_PASS:-}" ]] && echo "-pass env:PKI_OWNER_ROOT_PASS" || true; }
pass_in()  { [[ -n "${PKI_OWNER_ROOT_PASS:-}" ]] && echo "-passin env:PKI_OWNER_ROOT_PASS" || true; }

check_clock() {
  [[ ! "$(date -u +%F)" < "$DATE_FLOOR" ]] \
    || die "the clock says $(date -u +%F), before $DATE_FLOOR - set it first: every certificate's validity starts from it"
}
check_org() {
  [[ -n "$1" ]] || die "--org: the organization name the CAs carry, such as 'Mabell Home'"
  [[ "${#1}" -le 48 ]] || die "--org: 48 characters at most"
  [[ "$1" =~ ^[[:alnum:]][[:alnum:][:space:].,\&\'-]*$ ]] \
    || die "--org '$1': letters, digits, spaces and . , & ' - only"
}
check_domain() {
  [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$ ]] \
    || die "--domain '$1' is not a domain name (lower case, no trailing dot)"
  case "$1" in local|*.local|localhost) die "--domain $1: .local and localhost are always permitted" ;; esac
}

# The names the issuing CA may sign for.
permitted() {
  local d out="permitted;DNS:local,permitted;DNS:localhost"
  for d in "$@"; do out+=",permitted;DNS:$d"; done
  out+=",permitted;IP:10.0.0.0/255.0.0.0,permitted;IP:172.16.0.0/255.240.0.0"
  out+=",permitted;IP:192.168.0.0/255.255.0.0,permitted;IP:127.0.0.0/255.0.0.0"
  out+=",permitted;IP:fc00::/fe00::,permitted;IP:::1/ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"
  echo "$out"
}

# --- the stick ---------------------------------------------------------------
# Only an encrypted filesystem holds the root: a mount whose source is a
# dm-crypt device. A plain stick is refused, and so is a directory on the Pi.
encrypted_mount() {
  local src
  src="$(findmnt -no SOURCE --target "$1" 2>/dev/null)" || return 1
  [[ -b "$src" && "$(lsblk -dno TYPE "$src" 2>/dev/null)" == crypt ]]
}
check_keys_dir() {
  [[ -d "$1" ]] || die "--keys $1: no such directory"
  if [[ "${DEEVNET_PKI_OWNER_TEST_PLAIN_KEYS:-}" == "I know this is only a test" ]]; then
    say "TEST: $1 is not checked for encryption"
    return
  fi
  encrypted_mount "$1" || die "--keys $1 is not on an encrypted stick: the root key is written only to one (deevnet-pki-media.sh keys init)"
}

usb_disks() {
  if [[ "${DEEVNET_PKI_MEDIA_TRAN:-usb}" == loop ]]; then
    lsblk -dnro NAME,TYPE,SIZE | awk '$2=="loop" && $3!="0B" {print $1}'
  else
    lsblk -dnro NAME,TRAN | awk '$2=="usb" {print $1}'
  fi | sort
}
# Prints /dev/<name> of the one drive inserted after the prompt.
wait_for_drive() {
  local before new a i
  while true; do
    before="$(usb_disks)"
    read -r -p "  Insert the USB stick for your root key, then press Enter. " a </dev/tty
    new=""
    for i in $(seq 1 20); do
      new="$(comm -13 <(echo "$before") <(usb_disks) | grep . || true)"
      [[ -n "$new" ]] && break
      sleep 1
    done
    if [[ -z "$new" ]]; then
      echo "  No new drive appeared. If it was already in, take it out and press Enter, then insert it." >&2; continue
    fi
    [[ "$(echo "$new" | wc -l)" -eq 1 ]] || { echo "  More than one drive appeared; insert only the stick." >&2; continue; }
    echo "/dev/$new"; return
  done
}

KEYS=""; opened=""; WORK=""
close_stick() { [[ -n "$opened" ]] && "$MEDIA" keys close >/dev/null 2>&1 || true; }
cleanup() { [[ -n "$WORK" ]] && rm -rf "$WORK"; close_stick; }
trap cleanup EXIT

# Opens the owner's stick at $DEEVNET_PKI_KEYS_MNT, or, for init only, makes one.
open_stick() {
  local mode="$1" dev label a
  [[ $EUID -eq 0 ]] || die "the stick needs root: run it with sudo"
  ! mountpoint -q "$DEEVNET_PKI_KEYS_MNT" || die "$DEEVNET_PKI_KEYS_MNT is already mounted - close it first ($MEDIA keys close)"
  dev="$(wait_for_drive)"
  label="$(blkid -s LABEL -o value "$dev" 2>/dev/null || true)"
  if [[ "$(blkid -s TYPE -o value "$dev" 2>/dev/null)" == crypto_LUKS && "$label" == owner-keys-* ]]; then
    say "That is your key stick, $label. It asks for the stick's passphrase."
    "$MEDIA" keys open "${label#owner-keys-}"
  elif [[ "$mode" == init ]]; then
    lsblk -o NAME,SIZE,MODEL,LABEL,FSTYPE "$dev" | sed 's/^/    /'
    say "That stick is not a key stick yet. Making it one ERASES it, and encrypts it with"
    say "a passphrase of its own: without that passphrase, the stick is unreadable."
    read -r -p "  Erase it and make it your key stick? [y/N] " a </dev/tty
    [[ "${a,,}" == y || "${a,,}" == yes ]] || die "stopped - nothing was changed"
    "$MEDIA" keys init "$dev" primary
  else
    die "$dev is not your key stick (no LUKS volume labelled owner-keys-*) - nothing was changed"
  fi
  opened=yes
  KEYS="$DEEVNET_PKI_KEYS_MNT"
  encrypted_mount "$KEYS" || die "the stick did not open as an encrypted filesystem at $KEYS"
}

# --- init and issuing --------------------------------------------------------
make_root() {
  local work="$1"
  [[ ! -e "$KEYS/$ROOT_KEY" ]] \
    || die "the stick already holds $ROOT_KEY - a root is made once; for a new card run: deevnet-pki-owner.sh issuing"
  say "Your root key: ECDSA P-256, encrypted with a passphrase as it is made. openssl asks"
  say "for the passphrase. Without it the key is useless, and without the key, the passphrase."
  # shellcheck disable=SC2046
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -aes-256-cbc $(pass_out) -out "$work/$ROOT_KEY"
  PKI_OWNER_ORG="$ORG" PKI_OWNER_CN="$ORG Root CA" \
    openssl req -x509 -new -config "$PROFILE" -key "$work/$ROOT_KEY" $(pass_in) \
      -extensions v3_owner_root -days "$ROOT_DAYS" -sha256 \
      -set_serial "0x$(openssl rand -hex 16)" -out "$work/$ROOT_CERT"
  cp "$work/$ROOT_KEY" "$work/$ROOT_CERT" "$KEYS/" && sync
  cmp -s "$work/$ROOT_KEY" "$KEYS/$ROOT_KEY" && cmp -s "$work/$ROOT_CERT" "$KEYS/$ROOT_CERT" \
    || die "the root did not reach the stick intact"
  chmod 0600 "$KEYS/$ROOT_KEY"
  say "Your root, $ORG Root CA, 20 years, is on the stick."
}

make_issuing() {
  local work="$1" cn
  [[ -r "$KEYS/$ROOT_KEY" && -r "$KEYS/$ROOT_CERT" ]] || die "the stick holds no $ROOT_KEY and $ROOT_CERT"
  [[ ! -e "$OUT/$ISSUING_KEY" ]] \
    || die "$OUT already holds $ISSUING_KEY - move it aside first; nothing was changed"
  cn="$ORG Issuing CA $(hostname -s) $(date -u +%F)"
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$work/$ISSUING_KEY"
  PKI_OWNER_ORG="$ORG" PKI_OWNER_CN="$cn" \
    openssl req -new -config "$PROFILE" -key "$work/$ISSUING_KEY" -out "$work/issuing.csr"
  say "The root signs the issuing CA: it asks for the ROOT key's passphrase."
  # shellcheck disable=SC2046
  PKI_OWNER_PERMITTED="$(permitted "${DOMAINS[@]}")" \
    openssl x509 -req -in "$work/issuing.csr" -CA "$KEYS/$ROOT_CERT" -CAkey "$KEYS/$ROOT_KEY" $(pass_in) \
      -extfile "$PROFILE" -extensions v3_owner_issuing -days "$ISSUING_DAYS" -sha256 \
      -set_serial "0x$(openssl rand -hex 16)" -out "$work/$ISSUING_CERT"
  openssl verify -no-CApath -no-CAstore -CAfile "$KEYS/$ROOT_CERT" "$work/$ISSUING_CERT" >/dev/null \
    || die "the issuing CA does not verify against the root - nothing written"
  [[ "$(pubkey_hash x509 "$work/$ISSUING_CERT")" == "$(pubkey_hash key "$work/$ISSUING_KEY")" ]] \
    || die "the issuing CA's certificate is not for its key - nothing written"
  mkdir -p "$OUT"
  install -m 0600 "$work/$ISSUING_KEY" "$OUT/$ISSUING_KEY"
  install -m 0644 "$work/$ISSUING_CERT" "$OUT/$ISSUING_CERT"
  install -m 0644 "$KEYS/$ROOT_CERT" "$OUT/$ROOT_CERT"
  [[ ! -e "$OUT/$ROOT_KEY" ]] || die "$OUT/$ROOT_KEY exists: the root key belongs only on the stick - remove it"
  say "Issuing CA: $cn, 5 years, in $OUT."
}

cmd_ca() {
  local mode="$1"; shift
  ORG=""; OUT=""; DOMAINS=()
  local keys=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --org)    ORG="${2:-}"; shift 2 ;;
      --domain) DOMAINS+=("${2:-}"); shift 2 ;;
      --out)    OUT="${2:-}"; shift 2 ;;
      --keys)   keys="${2:-}"; shift 2 ;;
      *) die "unknown option $1" ;;
    esac
  done
  check_org "$ORG"
  [[ -n "$OUT" ]] || die "--out: where the issuing CA goes"
  local d; for d in "${DOMAINS[@]}"; do check_domain "$d"; done
  [[ -r "$PROFILE" ]] || die "no profile at $PROFILE"
  check_clock
  if [[ -n "$keys" ]]; then check_keys_dir "$keys"; KEYS="$keys"; else open_stick "$mode"; fi

  WORK="$(mktemp -d /dev/shm/deevnet-pki-owner.XXXXXX)"; local work="$WORK"
  [[ "$mode" == init ]] && make_root "$work"
  make_issuing "$work"
  echo
  say "Write down your root's fingerprint, and keep it with the stick:"
  say "  $(fingerprint "$KEYS/$ROOT_CERT")"
  say "Computers and devices trust $OUT/$ROOT_CERT. Keep the stick apart from the Pi:"
  say "it is needed again only for a new issuing CA."
}

# --- leaf --------------------------------------------------------------------
cmd_leaf() {
  local kind="${1:-}"; shift || true
  [[ "$kind" == server || "$kind" == device ]] || die "leaf server|device"
  local ca="" out="" csr="" days="$LEAF_DAYS" names=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ca)   ca="${2:-}"; shift 2 ;;
      --out)  out="${2:-}"; shift 2 ;;
      --csr)  csr="${2:-}"; shift 2 ;;
      --days) days="${2:-}"; shift 2 ;;
      --name) names+=("${2:-}"); shift 2 ;;
      *) die "unknown option $1" ;;
    esac
  done
  [[ -r "$ca/$ISSUING_KEY" && -r "$ca/$ISSUING_CERT" && -r "$ca/$ROOT_CERT" ]] \
    || die "--ca $ca: no issuing CA there ($ISSUING_KEY, $ISSUING_CERT, $ROOT_CERT)"
  [[ -n "$out" ]] || die "--out: where the certificate goes"
  [[ "$days" =~ ^[0-9]+$ && "$days" -ge 1 && "$days" -le "$LEAF_DAYS" ]] || die "--days: 1 to $LEAF_DAYS"
  [[ ${#names[@]} -ge 1 ]] || die "--name: at least one"
  [[ -r "$PROFILE" ]] || die "no profile at $PROFILE"
  check_clock

  local cn san="" n ext purpose base
  if [[ "$kind" == device ]]; then
    [[ ${#names[@]} -eq 1 ]] || die "a device certificate names one device"
    [[ "${names[0]}" =~ ^[a-z0-9]([a-z0-9._-]{0,62}[a-z0-9])?$ ]] || die "--name '${names[0]}': lower-case letters, digits, . _ -"
    cn="${names[0]}"; ext=v3_owner_device; purpose=sslclient
  else
    for n in "${names[@]}"; do
      if [[ "$n" =~ ^[0-9.]+$ || "$n" == *:* ]]; then
        san+="${san:+,}IP:$n"
      elif [[ "$n" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
        san+="${san:+,}DNS:$n"; cn="${cn:-$n}"
      else
        die "--name '$n' is neither a host name nor an address"
      fi
    done
    [[ -n "$cn" ]] || die "a server certificate names at least one host name"
    ext=v3_owner_server; purpose=sslserver
  fi
  base="${cn}"
  mkdir -p "$out"
  [[ ! -e "$out/$base.pem" ]] || die "$out/$base.pem exists - move it aside first; nothing was changed"

  WORK="$(mktemp -d /dev/shm/deevnet-pki-leaf.XXXXXX)"; local work="$WORK"
  if [[ -n "$csr" ]]; then
    openssl req -in "$csr" -noout -verify >/dev/null 2>&1 || die "--csr $csr: its signature does not verify"
    cp "$csr" "$work/leaf.csr"
  else
    [[ ! -e "$out/$base.key" ]] || die "$out/$base.key exists - move it aside first; nothing was changed"
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$work/leaf.key"
    PKI_OWNER_CN="$cn" openssl req -new -config "$PROFILE" -key "$work/leaf.key" -subj "/CN=$cn" -out "$work/leaf.csr"
  fi
  # The request's subject and extensions are not used: the subject is the name
  # given, and the extensions are the profile's.
  PKI_OWNER_SAN="${san:-DNS:invalid}" \
    openssl x509 -req -in "$work/leaf.csr" -CA "$ca/$ISSUING_CERT" -CAkey "$ca/$ISSUING_KEY" \
      -subj "/CN=$cn" -extfile "$PROFILE" -extensions "$ext" -days "$days" -sha256 \
      -set_serial "0x$(openssl rand -hex 16)" -out "$work/leaf.pem" 2>"$work/err" \
    || { cat "$work/err" >&2; die "signing failed - nothing written"; }
  # openssl verify enforces the issuing CA's name constraints: a name outside
  # the owner's is refused here, before anything is written.
  openssl verify -no-CApath -no-CAstore -CAfile "$ca/$ROOT_CERT" -untrusted "$ca/$ISSUING_CERT" \
      -purpose "$purpose" "$work/leaf.pem" >"$work/verify" 2>&1 \
    || { sed 's/^/    /' "$work/verify" >&2; die "the certificate does not verify - nothing written. A 'permitted subtree violation' is a name outside this CA's: only .local names, its domains, localhost, and private and loopback addresses; a bare host name such as 'mypi' is none of them, so give 'mypi.local'"; }
  if [[ -z "$csr" ]]; then install -m 0600 "$work/leaf.key" "$out/$base.key"; fi
  install -m 0644 "$work/leaf.pem" "$out/$base.pem"
  cat "$work/leaf.pem" "$ca/$ISSUING_CERT" > "$work/fullchain.pem"
  install -m 0644 "$work/fullchain.pem" "$out/$base-fullchain.pem"
  say "$kind certificate for $cn, $days days: $out/$base.pem (and $base-fullchain.pem)"
}

case "${1:-}" in
  init|issuing) m="$1"; shift; cmd_ca "$m" "$@" ;;
  leaf) shift; cmd_leaf "$@" ;;
  *) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
