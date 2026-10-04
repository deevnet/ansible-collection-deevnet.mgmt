#!/usr/bin/env bash
# The Root CA and Site CA ceremonies, step by step (runbook: Root of Trust >
# Root CA, Site CA). On the pi-pki ceremony image it is /home/pki/deevnet-pki-ceremony.sh:
#
#   ./deevnet-pki-ceremony.sh
#
# It runs the runbook's own commands, one step at a time: it says what the
# next step does, asks Proceed? [Y/n], and waits for the operator's input
# where a step needs it (a device, a site name, a passphrase). Answering n
# stops it; nothing is lost that is not already on a key drive, and the
# working directory in RAM is gone at power-off.
#
# Three paths:
#   1. a new Deevnet Root CA and a Site CA - the first ceremony, or a re-root;
#   2. a Site CA only, signed by the root already on the key drive - a new
#      site, or a Site CA rotation;
#   3. sign an issuing CA from a request on the transfer drive, with
#      deevnet-pki-sign.sh, as many as the operator brings, one round trip of
#      the transfer drive each.
#
# It asks for each USB drive when it needs it (start with none plugged in) and
# recognizes what arrives: a key drive or transfer drive already made is
# opened, any other drive is formatted as one only after the operator agrees.
# The backup key drive is optional; it can be made later.
#
# It never overwrites a key: a key drive that already holds the CA it would
# make stops it.
set -euo pipefail

PROFILE="${DEEVNET_PKI_PROFILE:-/usr/local/share/deevnet-pki/deevnet-pki.cnf}"
RELEASE="${DEEVNET_PKI_RELEASE:-/etc/deevnet-pki-release}"
MEDIA="${DEEVNET_PKI_MEDIA:-deevnet-pki-media.sh}"
WORK="${DEEVNET_PKI_WORK:-/dev/shm/pki}"
KEYS="${DEEVNET_PKI_KEYS_MNT:-/mnt/keys}"
TRANSFER="${DEEVNET_PKI_TRANSFER_MNT:-/mnt/transfer}"
DATE_FLOOR="2026-10-03"

ROOT_DAYS=7305   # 20 years
SITE_DAYS=3653   # 10 years

bold=$'\e[1m'; dim=$'\e[2m'; red=$'\e[31m'; green=$'\e[32m'; off=$'\e[0m'
[[ -t 1 ]] || { bold=""; dim=""; red=""; green=""; off=""; }

die()  { echo "${red}deevnet-pki-ceremony.sh: $*${off}" >&2; exit 1; }
step() { echo; echo "${bold}== $* ==${off}"; }
say()  { echo "   $*"; }
run()  { echo "${dim}   \$ $*${off}"; "$@"; }
proceed() {
  local a
  read -r -p "   Proceed? [Y/n] " a
  case "${a,,}" in ""|y|yes) return 0 ;; *) stopped ;; esac
}
stopped() {
  echo
  say "Stopped. Keys made this session are in $WORK until power-off, and on a key"
  say "drive only if that step ran. To close the drives:"
  say "  sudo $MEDIA keys close; sudo $MEDIA transfer umount"
  exit 0
}
fingerprint() { openssl x509 -in "$1" -noout -fingerprint -sha256 | sed 's/^.*=//'; }
show_cert() {
  openssl x509 -in "$1" -noout -subject -issuer -enddate -ext basicConstraints,keyUsage,nameConstraints -nameopt multiline,-esc_msb \
    | sed 's/^/     /'
  say "SHA-256 fingerprint: ${bold}$(fingerprint "$1")${off}"
}
paper=()   # what to write in the paper record, shown again at the end

# --- USB drives -------------------------------------------------------------
# The script asks for each drive when it needs it and sees which one arrived,
# so nothing depends on knowing /dev/sda from /dev/sdb. Tests use loop devices
# (DEEVNET_PKI_MEDIA_TRAN=loop, as deevnet-pki-media.sh does).
usb_disks() {
  if [[ "${DEEVNET_PKI_MEDIA_TRAN:-usb}" == loop ]]; then
    lsblk -dnro NAME,TYPE,SIZE | awk '$2=="loop" && $3!="0B" {print $1}'
  else
    lsblk -dnro NAME,TRAN | awk '$2=="usb" {print $1}'
  fi | sort
}
wait_until_no_drives() {
  local a
  while [[ -n "$(usb_disks)" ]]; do
    say "Plugged in now: $(usb_disks | tr '\n' ' ')"
    read -r -p "   Remove every USB drive (the keyboard can stay), then press Enter. " a
  done
}
# Prints /dev/<name> of the one drive inserted after the prompt.
wait_for_drive() {
  local what="$1" before new a i
  while true; do
    before="$(usb_disks)"
    read -r -p "   Insert the ${bold}$what${off}, then press Enter. " a </dev/tty
    for i in $(seq 1 20); do
      new="$(comm -13 <(echo "$before") <(usb_disks) | grep . || true)"
      [[ -n "$new" ]] && break
      sleep 1
    done
    if [[ -z "$new" ]]; then
      echo "   No new drive appeared. Check it is pushed in, and try again." >&2; continue
    fi
    if [[ "$(echo "$new" | wc -l)" -gt 1 ]]; then
      echo "   More than one new drive appeared ($(echo $new)). Remove the extra one and try again." >&2
      continue
    fi
    echo "/dev/$new"; return
  done
}
wait_for_removal() {
  local dev="$1" a
  while usb_disks | grep -qx "$(basename "$dev")"; do
    read -r -p "   Remove that drive ($dev), then press Enter. " a
  done
}
# A Pi 4 can drop one USB drive when another is plugged in (the new drive's
# inrush current dips the bus), and a dropped drive keeps its name with a size
# of zero: every write to it fails. So drives are checked before every write,
# and a dropped one is reseated and reopened while the keys wait in RAM.
alive() { local n; n="$(basename "$1")"; [[ -r "/sys/block/$n/size" && "$(cat "/sys/block/$n/size")" -gt 0 ]]; }
backing_disk() {   # the disk under a mount point, through dm-crypt if need be
  local src pk
  src="$(findmnt -no SOURCE "$1" 2>/dev/null)" || return 1
  if [[ "$src" == /dev/mapper/* ]]; then
    src="/dev/$(ls "/sys/block/$(basename "$(readlink -f "$src")")/slaves" 2>/dev/null | head -1)"
  fi
  pk="$(lsblk -no PKNAME "$src" 2>/dev/null | head -1 || true)"
  if [[ -n "$pk" ]]; then echo "/dev/$pk"; else echo "$src"; fi
}
writable() {       # mounted, its disk still there, and a write lands
  local mnt="$1" disk
  mountpoint -q "$mnt" || return 1
  disk="$(backing_disk "$mnt")" && alive "$disk" || return 1
  touch "$mnt/.deevnet-write-test" 2>/dev/null && rm -f "$mnt/.deevnet-write-test" && sync
}
recover_key_drive() {
  local a dev
  echo "   ${red}The key drive stopped responding${off} - most likely it dropped off the USB bus."
  say "The keys made this session are safe in $WORK. Reseat the drive and the script"
  say "will reopen it and copy them again. Use the black (USB 2) ports if you can."
  sudo umount -l "$KEYS" 2>/dev/null || true
  sudo cryptsetup close deevnet-keys 2>/dev/null || sudo dmsetup remove --force deevnet-keys 2>/dev/null || true
  read -r -p "   Pull out the key drive (leave the transfer drive in), then press Enter. " a
  dev="$(wait_for_drive "KEY drive again")"
  key_drive primary "$dev"
}
recover_transfer_drive() {
  local a dev
  echo "   ${red}The transfer drive stopped responding${off} - most likely it dropped off the USB bus."
  say "The certificates are safe in $WORK. Reseat it and the script will copy them again."
  sudo umount -l "$TRANSFER" 2>/dev/null || true
  read -r -p "   Pull out the transfer drive (leave the key drive in), then press Enter. " a
  dev="$(wait_for_drive "TRANSFER drive again")"
  transfer_drive "$dev"
}
# Copy files to a drive, check each landed byte for byte, and on any failure
# recover the drive and try again.
store() {
  local where="$1"; shift
  local mnt f ok
  [[ "$where" == keys ]] && mnt="$KEYS" || mnt="$TRANSFER"
  while true; do
    ok=1
    if writable "$mnt"; then
      for f in "$@"; do
        run cp "$f" "$mnt/" && sync && cmp -s "$f" "$mnt/$(basename "$f")" || { ok=0; break; }
      done
    else
      ok=0
    fi
    [[ "$ok" == 1 ]] && return 0
    if [[ "$where" == keys ]]; then recover_key_drive; else recover_transfer_drive; fi
  done
}

# Opens the key drive in $dev (one already made), or offers to make it.
key_drive() {
  local copy="$1" dev="$2" label a
  # sudo: as the pki user, blkid cannot read a raw drive and finds nothing.
  label="$(sudo blkid -s LABEL -o value "$dev" 2>/dev/null || true)"
  if [[ "$(sudo blkid -s TYPE -o value "$dev" 2>/dev/null)" == crypto_LUKS && "$label" == deevnet-keys-* ]]; then
    say "That is ${bold}$label${off}. Opening it: it asks for the drive's passphrase."
    [[ "$label" == "deevnet-keys-$copy" ]] || say "(It is labeled for the other copy; it is used as the $copy all the same.)"
    sudo "$MEDIA" keys open "${label#deevnet-keys-}"
  else
    lsblk -o NAME,SIZE,MODEL,LABEL,FSTYPE "$dev" | sed 's/^/     /'
    say "That drive is not a Deevnet key drive."
    [[ "${can_format:-yes}" == yes ]] || die "signing needs the key drive that holds the Site CA - nothing was changed"
    read -r -p "   Make it the $copy key drive? This ERASES it. [y/N] " a
    [[ "${a,,}" == y || "${a,,}" == yes ]] || stopped
    sudo "$MEDIA" keys init "$dev" "$copy"
    paper+=("Key drive deevnet-keys-$copy made $(date -u +%F)")
  fi
  mountpoint -q "$KEYS" || die "the key drive is not open at $KEYS"
}
transfer_drive() {
  local dev="$1" a
  local p found=""
  # blkid reads the drive itself (lsblk's labels come from udev's database), and
  # needs sudo to do it as the pki user.
  for p in $(lsblk -nro PATH "$dev"); do
    [[ "$(sudo blkid -s LABEL -o value "$p" 2>/dev/null)" == TRANSFER ]] && found="$p"
  done
  if [[ -n "$found" ]]; then
    say "That is the ${bold}transfer drive${off}."
  else
    lsblk -o NAME,SIZE,MODEL,LABEL,FSTYPE "$dev" | sed 's/^/     /'
    say "That drive is not a transfer drive."
    [[ "${can_format:-yes}" == yes ]] || die "signing needs the transfer drive the Builder prepared - nothing was changed"
    read -r -p "   Make it the transfer drive (plain FAT32)? This ERASES it. [y/N] " a
    [[ "${a,,}" == y || "${a,,}" == yes ]] || stopped
    sudo "$MEDIA" transfer init "$dev"
  fi
  sudo "$MEDIA" transfer mount
  mountpoint -q "$TRANSFER" || die "the transfer drive is not mounted at $TRANSFER"
}

# ---------------------------------------------------------------------------
step "Deevnet Root of Trust ceremony"
say "This makes the Deevnet PKI's offline CAs, as the Root of Trust runbook does."
say "Each step says what it does and asks before it runs. Have ready:"
say "  - the key drive and the transfer drive (and a backup key drive, if you have one),"
say "    not plugged in yet: the script asks for each when it needs it;"
say "  - the paper record;"
say "  - the passphrases: one for each key drive, one for the key files."
echo
say "1. A new Deevnet Root CA, then a Site CA (first time, or a re-root)"
say "2. A Site CA only, signed by the root already on the key drive (a new site, or a rotation)"
say "3. Sign an issuing CA (Substrate or Tenant Device), from a request the Builder put on"
say "   the transfer drive with deevnet-pki-transfer.sh prepare"
read -r -p "   Which? [1/2/3] " path
[[ "$path" == 1 || "$path" == 2 || "$path" == 3 ]] || die "answer 1, 2 or 3"
# Path 3 only uses drives already made: it never formats one.
can_format=yes; [[ "$path" == 3 ]] && can_format=no

# ---------------------------------------------------------------------------
step "Check this machine is offline, and its clock"
say "No network interface may be up. The clock must be right: every certificate's"
say "validity starts from it, and a Pi has no battery clock."
proceed
if ip -brief address 2>/dev/null | grep -v '^lo ' | grep -q UP; then
  die "a network interface is up - this machine must be offline"
fi
say "${green}offline${off}: only lo is up"
floor="$DATE_FLOOR"
if [[ -r "$RELEASE" ]]; then
  built="$(sed -n 's/^built=//p' "$RELEASE")"; [[ -n "$built" && "$built" > "$floor" ]] && floor="$built"
fi
[[ ! "$(date -u +%F)" < "$floor" ]] || die "the clock says $(date -u +%F), before $floor - set it: sudo date -u -s 'YYYY-MM-DD HH:MM'"
say "The clock says ${bold}$(date -u '+%F %H:%M') UTC${off}."
read -r -p "   Is that today's date and time, in UTC? [y/N] " ok
[[ "${ok,,}" == y || "${ok,,}" == yes ]] || die "set it first: sudo date -u -s 'YYYY-MM-DD HH:MM', then run this again"
[[ -r "$PROFILE" ]] || die "no signing profile at $PROFILE"

# ---------------------------------------------------------------------------
step "Make the working directory in memory"
say "Keys are made in $WORK, in RAM: nothing there survives power-off. The signing"
say "profile is copied beside them."
proceed
mkdir -p -m 0700 "$WORK"
cp "$PROFILE" "$WORK/deevnet-pki.cnf"
cd "$WORK"
say "${green}ready${off}: $WORK"

# ---------------------------------------------------------------------------
step "The drives"
if [[ "$path" == 3 ]]; then
  say "The script asks for each drive when it needs it: the key drive holding the"
  say "Site CA, then the transfer drive the Builder prepared. Nothing is formatted on"
  say "this path. First, start with none plugged in."
else
  say "The script asks for each drive when it needs it, and recognizes it: a drive"
  say "already prepared is opened, a new one is formatted (after you agree; that"
  say "ERASES it). First, start with none plugged in."
fi
proceed
wait_until_no_drives
say "Both drives go in first, one after the other, before either is touched: plugging"
say "a drive into a Pi can knock another one off the bus while it is busy."
key_dev="$(wait_for_drive "KEY drive (the primary)")"
transfer_dev="$(wait_for_drive "TRANSFER drive")"
say "Waiting a few seconds for both to settle..."
sleep 5
alive "$key_dev" || die "the key drive ($key_dev) dropped off the bus when the transfer drive went in. Power off, use the black (USB 2) ports or a powered hub, and start again."
alive "$transfer_dev" || die "the transfer drive ($transfer_dev) dropped off the bus. Power off, use the black (USB 2) ports or a powered hub, and start again."
say "Both are in. Leave them in until the script says to take one out."
key_drive primary "$key_dev"
transfer_drive "$transfer_dev"
say "${green}ready${off}: key drive open at $KEYS, transfer drive at $TRANSFER"

# ---------------------------------------------------------------------------
if [[ "$path" == 3 ]]; then
  IN="$TRANSFER/deevnet-transfer/to-offline"
  OUT="$TRANSFER/deevnet-transfer/to-online"
  while true; do
    [[ -f "$IN/MANIFEST" ]] || die "the transfer drive has no request - prepare it on the Builder first (deevnet-pki-transfer.sh prepare)"
    csr="$(ls "$IN"/*.csr 2>/dev/null | head -1 || true)"
    [[ -n "$csr" ]] || die "no request (.csr) in $IN"
    name="$(basename "$csr" .csr)"                       # deevnet-<site>-<ca>-ca
    site="$(echo "$name" | sed -n 's/^deevnet-\([a-z0-9]*\)-.*/\1/p')"
    site_key="$KEYS/deevnet-$site-site-ca.key"
    [[ -r "$site_key" ]] || die "the key drive has no deevnet-$site-site-ca.key to sign $name with"

    SITE_OF_SITE="${site^}"
    step "Sign an issuing CA: $name"
    say "The request on the transfer drive:"
    openssl req -in "$csr" -noout -subject -nameopt RFC2253 | sed 's/^/     /'
    say "deevnet-pki-sign.sh now checks the machine is offline, the transfer drive holds no"
    say "private key, the manifest matches its files, and the request's signature. It shows"
    say "the manifest's hash and the request's key hash: ${bold}compare both with the paper record${off}"
    say "(the Builder printed them). It asks for the clock (answer yes), the $SITE_OF_SITE Site"
    say "CA key's passphrase, and finally the CA's name, typed exactly: that is the decision"
    say "to sign. It writes only the certificate and a manifest back to the transfer drive."
    proceed
    writable "$TRANSFER" || recover_transfer_drive
    run deevnet-pki-sign.sh "$TRANSFER" --site-key "$site_key" || die "deevnet-pki-sign.sh stopped - nothing was signed, or see its message"
    sync
    cert="$OUT/$name.pem"
    [[ -r "$cert" ]] || die "no certificate came back in $OUT"
    paper+=("$(openssl x509 -in "$cert" -noout -subject -nameopt RFC2253 | sed 's/^subject=//'), 5 years, $(date -u +%F): $(fingerprint "$cert")")
    say "${bold}Write the certificate's fingerprint in the paper record:${off} $(fingerprint "$cert")"

    read -r -p "   Another request to sign in this session? [y/N] " a
    [[ "${a,,}" == y || "${a,,}" == yes ]] || break
    step "Swap the transfer drive"
    say "The key drive closes while the transfer drive travels: nothing is plugged in"
    say "beside an open key drive. Take the transfer drive to the Builder, have it accept"
    say "this certificate and prepare the next request, then bring it back."
    proceed
    key_disk="$(backing_disk "$KEYS")"
    sudo "$MEDIA" keys close
    sudo "$MEDIA" transfer umount
    while usb_disks | grep -vqx "$(basename "$key_disk")"; do
      read -r -p "   Take out the transfer drive (leave the key drive in), then press Enter. " a
    done
    dev="$(wait_for_drive "TRANSFER drive, with the next request")"
    sleep 3
    alive "$key_disk" || die "the key drive dropped off the bus when the transfer drive went in. Power off, use the black (USB 2) ports, and start again."
    transfer_drive "$dev"
    say "Reopening the key drive: it asks for the drive's passphrase."
    sudo "$MEDIA" keys open
  done

  step "Finish"
  say "The transfer drive carries back:"
  ls -1 "$OUT" | sed 's/^/     /'
  say "For the paper record:"
  for p in "${paper[@]}"; do say "  - $p"; done
  say "Next: close both drives and power off. On the Builder, deevnet-pki-transfer.sh accept"
  say "checks the certificate against the request and the inventory's root and Site CA."
  proceed
  sudo "$MEDIA" keys close
  sudo "$MEDIA" transfer umount
  read -r -p "   Power off now? [Y/n] " a
  case "${a,,}" in n|no) ;; *) sudo poweroff ;; esac
  exit 0
fi

# ---------------------------------------------------------------------------
if [[ "$path" == 1 ]]; then
  [[ ! -e "$KEYS/deevnet-root-ca.key" ]] \
    || die "this key drive already holds deevnet-root-ca.key - a root is made once; nothing was changed"

  step "Root CA, 1 of 4: generate the key"
  say "An RSA 4096 key, encrypted with a passphrase as it is made. openssl asks for"
  say "the passphrase twice. Without the passphrase the file is useless, and without"
  say "the file the passphrase is."
  proceed
  run openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -aes-256-cbc -out deevnet-root-ca.key

  step "Root CA, 2 of 4: self-sign"
  say "The root signs its own certificate with the profile's v3_root extensions:"
  say "O=Deevnet, OU=Deevnet PKI, CN=Deevnet Root CA; 20 years; CA, path length 2."
  say "openssl asks for the key's passphrase."
  proceed
  run openssl req -x509 -new -config deevnet-pki.cnf -key deevnet-root-ca.key \
    -extensions v3_root -days "$ROOT_DAYS" -sha256 \
    -set_serial "0x$(openssl rand -hex 16)" -out deevnet-root-ca.pem

  step "Root CA, 3 of 4: check it"
  say "Check: subject and issuer are both Deevnet Root CA; it ends 20 years from today;"
  say "CA:TRUE, pathlen:2; Certificate Sign, CRL Sign."
  show_cert deevnet-root-ca.pem
  say "${bold}Write the fingerprint, today's date and 'Deevnet Root CA, 20 years' in the paper record.${off}"
  paper+=("Deevnet Root CA, 20 years, $(date -u +%F): $(fingerprint deevnet-root-ca.pem)")
  read -r -p "   Does it read correctly, and is it written down? [y/N] " a
  [[ "${a,,}" == y || "${a,,}" == yes ]] || stopped

  step "Root CA, 4 of 4: store it"
  say "The key and certificate go on the key drive, and the key is checked to open"
  say "(it asks for the key's passphrase). The certificate alone goes on the transfer drive."
  proceed
  store keys deevnet-root-ca.key deevnet-root-ca.pem
  run openssl pkey -in "$KEYS/deevnet-root-ca.key" -noout
  store transfer deevnet-root-ca.pem
  say "${green}stored${off}: the root is on the key drive, its certificate on the transfer drive"
fi

# ---------------------------------------------------------------------------
[[ -r "$KEYS/deevnet-root-ca.key" && -r "$KEYS/deevnet-root-ca.pem" ]] \
  || die "the key drive has no deevnet-root-ca.key and .pem - the Site CA needs the root"

step "Site CA: which site"
say "The site's name as in the naming standard, lower case (mobile, home, ...)."
read -r -p "   Site [mobile]: " site
site="${site:-mobile}"
[[ "$site" =~ ^[a-z][a-z0-9]{1,15}$ ]] || die "'$site' is not a site name"
SITE="${site^}"
[[ ! -e "$KEYS/deevnet-$site-site-ca.key" ]] \
  || die "this key drive already holds deevnet-$site-site-ca.key - to rotate it, move the old one aside first; nothing was changed"
say "Site CA: O=Deevnet, OU=$SITE Site, CN=Deevnet $SITE Site CA"

step "Site CA, 1 of 4: generate the key and request"
say "An RSA 3072 key, encrypted with a passphrase as it is made (asked twice), and"
say "a signing request naming the site. openssl asks for the key's passphrase again"
say "to sign the request."
proceed
run openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -aes-256-cbc -out "deevnet-$site-site-ca.key"
run openssl req -new -key "deevnet-$site-site-ca.key" \
  -subj "/O=Deevnet/OU=$SITE Site/CN=Deevnet $SITE Site CA" -out "deevnet-$site-site-ca.csr"

step "Site CA, 2 of 4: sign it with the root"
say "The root signs the request with the profile's v3_site extensions only, never the"
say "request's: 10 years; CA, path length 1; name constraints. openssl asks for the"
say "ROOT key's passphrase."
proceed
run openssl x509 -req -in "deevnet-$site-site-ca.csr" \
  -CA "$KEYS/deevnet-root-ca.pem" -CAkey "$KEYS/deevnet-root-ca.key" \
  -extfile deevnet-pki.cnf -extensions v3_site -days "$SITE_DAYS" -sha256 \
  -set_serial "0x$(openssl rand -hex 16)" -out "deevnet-$site-site-ca.pem"

step "Site CA, 3 of 4: check the chain"
say "Check: subject Deevnet $SITE Site CA, issuer the root; CA:TRUE, pathlen:1; ten years;"
say "Name Constraints permit only deevnet.net, localhost, and private and loopback"
say "addresses (so nothing under it can vouch for a public site); and it verifies"
say "against the root."
show_cert "deevnet-$site-site-ca.pem"
run openssl verify -no-CApath -no-CAstore -CAfile "$KEYS/deevnet-root-ca.pem" "deevnet-$site-site-ca.pem"
say "${bold}Write the fingerprint and 'Deevnet $SITE Site CA, 10 years' in the paper record.${off}"
paper+=("Deevnet $SITE Site CA, 10 years, $(date -u +%F): $(fingerprint "deevnet-$site-site-ca.pem")")
read -r -p "   Does it read correctly, and is it written down? [y/N] " a
[[ "${a,,}" == y || "${a,,}" == yes ]] || stopped

step "Site CA, 4 of 4: store it"
say "The key and certificate go on the key drive, and the key is checked to open"
say "(its passphrase). The certificate alone goes on the transfer drive."
proceed
store keys "deevnet-$site-site-ca.key" "deevnet-$site-site-ca.pem"
run openssl pkey -in "$KEYS/deevnet-$site-site-ca.key" -noout
store transfer "deevnet-$site-site-ca.pem"
say "${green}stored${off}: the Site CA is on the key drive, its certificate on the transfer drive"

# ---------------------------------------------------------------------------
step "The backup key drive (optional)"
say "Every key should exist on two key drives, kept apart. If you have the second"
say "drive now, this copies everything on the primary onto it. If not, skip it and"
say "make it later (the runbook has the steps): until then each key exists only once."
read -r -p "   Make or update the backup key drive now? [y/N] " a
if [[ "${a,,}" == y || "${a,,}" == yes ]]; then
  transfer_disk="$(lsblk -no PKNAME "$(findmnt -no SOURCE "$TRANSFER")")"
  run cp "$KEYS"/deevnet-*.key "$KEYS"/deevnet-*.pem "$WORK/"
  run sudo "$MEDIA" keys close
  say "Take out the primary key drive and put it aside; leave the transfer drive in."
  while usb_disks | grep -vqx "$transfer_disk"; do
    read -r -p "   Remove the primary key drive, then press Enter. " a
  done
  dev="$(wait_for_drive "BACKUP key drive")"
  key_drive backup "$dev"
  store keys "$WORK"/deevnet-*.key "$WORK"/deevnet-*.pem
  for k in "$KEYS"/deevnet-*.key; do run openssl pkey -in "$k" -noout; done
  say "${green}backup done${off}"
else
  say "${bold}No backup now: each key exists only once until you make it.${off}"
fi

# ---------------------------------------------------------------------------
step "Finish"
# The backup swap plugs a drive in beside the transfer drive: check it is still there.
writable "$TRANSFER" || { recover_transfer_drive; store transfer "$WORK"/deevnet-*.pem; }
say "The transfer drive holds:"
ls -1 "$TRANSFER"/*.pem | sed 's/^/     /'
say "For the paper record:"
for p in "${paper[@]}"; do say "  - $p"; done
say "Next: close both drives and power off. Take the transfer drive to the Builder."
proceed
sudo "$MEDIA" keys close
sudo "$MEDIA" transfer umount
read -r -p "   Power off now? [Y/n] " a
case "${a,,}" in n|no) say "Remember: $WORK holds keys until power-off." ;; *) sudo poweroff ;; esac
