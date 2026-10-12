#!/usr/bin/env bash
#
# platform-restore.sh - rebuild this platform onto a freshly installed Proxmox
# host from its own backups. Procedure and rationale:
# runbooks/platform/platform-restore.md.
#
# Deployed by the guest_backup role, so every host configuration archive carries
# a copy under /usr/local/sbin. On a host where nothing is deployed yet, take it
# from the repository.
#
# Subcommands, in the order a rebuild uses them:
#
#   plan          read-only. Checks the archive set against this machine and
#                 prints what the other subcommands would do. Safe on the live
#                 host, and the way to test the backups without a second machine.
#   test-restore  restores one container's newest archive under a spare ID,
#                 mounts it, lists it and destroys it again. Never starts it.
#   host          on a fresh install: brings back the host configuration the
#                 guests depend on. Refuses to run where guests already exist.
#   guests        restores every guest that does not exist yet, in dependency
#                 order, and starts them.
#   verify        reports guest state and what is left to do by hand.
#
# Options: --backup-dir DIR (default /mnt/vzdump), --archive FILE (host
# configuration archive, default the newest in DIR/host-config).

set -euo pipefail

BACKUP_DIR="/mnt/vzdump"
ARCHIVE=""
STORAGE="local-lvm"
STAGE="/root/platform-restore"

# Restore order. vm102 first: it serves the SMB shares the host mounts and that
# lxc260, lxc210 and lxc220 bind. lxc260 next, the database the others use.
# lxc250 late, because nothing depends on it and it is the node that runs
# Ansible once everything else is up. vm100 last; its data disk is not in the
# backup and is reattached from the auxiliary disk.
ORDER=(102 260 200 210 211 220 230 250 100)

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "== $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    plan|test-restore|host|guests|verify) CMD="$1"; shift
      [ "$CMD" = "test-restore" ] && { CTID="${1:-}"; shift || true; } ;;
    --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
    --archive)    ARCHIVE="$2"; shift 2 ;;
    *) sed -n '2,27p' "$0"; exit 2 ;;
  esac
done
[ -n "${CMD:-}" ] || { sed -n '2,27p' "$0"; exit 2; }
[ "$(id -u)" = 0 ] || die "run as root on the Proxmox host"

# Newest guest archive and whether its log reports success.
newest_archive() {  # <id>
  find "$BACKUP_DIR" -maxdepth 1 \( -name "vzdump-lxc-$1-*.tar.zst" -o -name "vzdump-qemu-$1-*.vma.zst" \) \
    -printf '%f\n' | sort | tail -1
}
archive_ok() {  # <file name>
  local log="${BACKUP_DIR}/${1%%.*}.log"
  [ -s "${BACKUP_DIR}/$1" ] && grep -q 'INFO: Finished Backup of VM' "$log" 2>/dev/null
}
guest_type() { case "$1" in vzdump-lxc-*) echo lxc ;; *) echo qemu ;; esac; }
exists() { qm status "$1" >/dev/null 2>&1 || pct status "$1" >/dev/null 2>&1; }

# Unpacks the host configuration archive into STAGE once and verifies it first.
unpack_archive() {
  if [ -z "$ARCHIVE" ]; then
    ARCHIVE="$(find "${BACKUP_DIR}/host-config" -maxdepth 1 -name 'host-config-*.tar.zst' 2>/dev/null | sort | tail -1)"
  fi
  [ -n "$ARCHIVE" ] && [ -f "$ARCHIVE" ] || die "no host configuration archive found; pass --archive"
  if [ -f "${ARCHIVE}.sha256" ]; then
    ( cd "$(dirname "$ARCHIVE")" && sha256sum -c --quiet "$(basename "$ARCHIVE").sha256" ) \
      || die "checksum mismatch: $ARCHIVE"
  fi
  if [ ! -d "${STAGE}/meta" ]; then
    install -d -m 0700 "$STAGE"
    tar --extract --zstd --file "$ARCHIVE" --directory "$STAGE"
  fi
  info "host configuration archive: $(basename "$ARCHIVE")"
}

# Every disk line a saved guest configuration names, which the restored one lacks
# and whose target exists here, is attached again. That covers the passthrough
# disks of vm102 and vm100's data disk, both of which carry backup=0 and so are
# not in the archive.
reattach_disks() {  # <id> <type>
  local id="$1" saved="${STAGE}/meta/guest-conf/$1.conf" key val vol path
  [ "$2" = qemu ] && [ -f "$saved" ] || return 0
  # Only the active section of the saved file, not its snapshots.
  { sed '/^\[/q' "$saved" | grep -E '^(scsi|sata|virtio|ide)[0-9]+: ' | grep -v 'media=cdrom' || true; } \
    | while IFS= read -r line; do
        key="${line%%:*}"; val="${line#*: }"
        qm config "$id" | grep -q "^${key}: " && continue
        vol="${val%%,*}"
        if [[ "$vol" == /dev/* ]]; then path="$vol"; else path="$(pvesm path "$vol" 2>/dev/null || true)"; fi
        if [ -n "$path" ] && [ -e "$path" ]; then
          echo "   reattach ${key}: ${vol}"; qm set "$id" "--${key}" "$val" >/dev/null
        else
          echo "   MISSING ${key}: ${vol} - not present on this host, left out" >&2
        fi
      done
}

case "$CMD" in

plan)
  unpack_archive
  M="${STAGE}/meta"
  info "Proxmox: saved $(head -1 "$M/pveversion.txt"), here $(pveversion -v | head -1)"
  info "guest archives in ${BACKUP_DIR}"
  gaps=0
  for id in "${ORDER[@]}"; do
    a="$(newest_archive "$id")"
    if [ -z "$a" ]; then echo "   ${id}: NO ARCHIVE"; gaps=$((gaps + 1))
    elif archive_ok "$a"; then echo "   ${id}: ${a}"
    else echo "   ${id}: ${a} - log does not report success"; gaps=$((gaps + 1)); fi
  done
  # Guests the saved host ran that ORDER does not know would be left behind.
  for f in "$M"/guest-conf/*.conf; do
    id="$(basename "$f" .conf)"
    [[ " ${ORDER[*]} " == *" $id "* ]] || { echo "   ${id}: on the saved host but not in ORDER"; gaps=$((gaps + 1)); }
  done
  info "disks the saved configurations attach directly"
  for f in "$M"/guest-conf/*.conf; do
    { sed '/^\[/q' "$f" | grep -oE '/dev/disk/by-id/[^,]+' || true; } | while read -r d; do
      if [ -e "$d" ]; then echo "   present: ${d##*/}"; else echo "   ABSENT:  ${d##*/}"; fi
    done
  done
  info "host files the 'host' step restores"
  for p in etc/fstab etc/modprobe.d/vfio.conf etc/modules etc/default/grub etc/pve/storage.cfg \
           etc/apt/sources.list.d/tailscale.list var/lib/tailscale/tailscaled.state root/.ssh/authorized_keys; do
    [ -e "${STAGE}/$p" ] && echo "   ok      /$p" || echo "   absent  /$p"
  done
  echo "   $(find "$M" -maxdepth 1 -name '.smbcredentials-*' | wc -l) CIFS credential files"
  if [ "$gaps" -gt 0 ]; then info "plan complete, ${gaps} gap(s)"; exit 1; fi
  info "plan complete, no gaps"
  ;;

test-restore)
  [ -n "${CTID:-}" ] || die "usage: test-restore <container id>"
  a="$(newest_archive "$CTID")"
  [ -n "$a" ] && [ "$(guest_type "$a")" = lxc ] || die "no container archive for ${CTID}"
  spare=$((900 + CTID % 100))
  exists "$spare" && die "spare ID ${spare} is in use"
  info "restoring ${a} as ${spare} on ${STORAGE}, not starting it"
  # The clone carries the original's network and Tailscale identity, so it must
  # never start. --unique gives it a new MAC address in case someone does.
  pct restore "$spare" "${BACKUP_DIR}/${a}" --storage "$STORAGE" --unique 1 >/dev/null
  trap 'pct unmount "$spare" 2>/dev/null || true; pct destroy "$spare" --purge 1 >/dev/null 2>&1 || true' EXIT
  mnt="$(pct mount "$spare" | sed -nE "s/.*'(.*)'.*/\1/p")"
  info "mounted at ${mnt}: $(find "$mnt" -xdev -type f 2>/dev/null | wc -l) files, $(cut -d' ' -f1 "$mnt/etc/hostname" 2>/dev/null || echo '?') as hostname"
  info "test-restore of ${CTID} passed; the clone is destroyed on exit"
  ;;

host)
  unpack_archive
  [ -z "$(qm list 2>/dev/null | tail -n +2)$(pct list 2>/dev/null | tail -n +2)" ] \
    || die "guests exist on this host - 'host' is for a fresh installation only"
  S="$STAGE"
  info "fstab: the saved /mnt entries are appended; root, EFI and swap stay the installer's"
  grep -E '^[^#].*[[:space:]]/mnt/' "${S}/etc/fstab" | while IFS= read -r l; do
    grep -qF -- "$l" /etc/fstab || echo "$l" >> /etc/fstab
  done
  grep -E '^[^#].*[[:space:]]/mnt/' "${S}/etc/fstab" | awk '{print $2}' | xargs -r mkdir -p
  info "CIFS credentials, root's keys, kernel module and boot configuration"
  install -m 0600 "${S}"/meta/.smbcredentials-* /root/
  install -d -m 0700 /root/.ssh && install -m 0600 "${S}/root/.ssh/authorized_keys" /root/.ssh/
  cp -a "${S}"/etc/modprobe.d/. /etc/modprobe.d/
  cp -a "${S}/etc/modules" /etc/modules
  cp -a "${S}/etc/default/grub" /etc/default/grub
  # Units and their enablement links, without overwriting what the installer wrote.
  cp -an "${S}/etc/systemd/system/." /etc/systemd/system/
  cp -a "${S}/usr/local/." /usr/local/
  info "storage definitions the guests name"
  # Stanzas absent from the fresh storage.cfg are appended whole.
  while IFS= read -r head; do
    grep -qxF "$head" /etc/pve/storage.cfg || awk -v h="$head" 'BEGIN{RS="";ORS="\n\n"} index($0,h)==1' \
      "${S}/etc/pve/storage.cfg" >> /etc/pve/storage.cfg
  done < <(grep -E '^[a-z]+: ' "${S}/etc/pve/storage.cfg")
  info "Tailscale: repository, package, and the saved node identity"
  cp -a "${S}/etc/apt/sources.list.d/tailscale.list" /etc/apt/sources.list.d/
  cp -a "${S}"/usr/share/keyrings/tailscale-archive-keyring.gpg /usr/share/keyrings/
  apt-get update -qq && apt-get install -y -qq tailscale >/dev/null
  systemctl stop tailscaled
  rm -rf /var/lib/tailscale && cp -a "${S}/var/lib/tailscale" /var/lib/tailscale
  systemctl start tailscaled
  info "applying: daemon-reload, mounts, grub, initramfs"
  systemctl daemon-reload
  mount -a || echo "   some mounts failed - check the data disks before 'guests'" >&2
  update-grub >/dev/null 2>&1
  update-initramfs -u -k all >/dev/null 2>&1
  diff -u "${S}/etc/network/interfaces" /etc/network/interfaces \
    || echo "   network configuration differs from the saved one - compare by hand, not changed here"
  info "host step done. Reboot, so IOMMU and vfio take effect, then run 'plan' and 'guests'"
  ;;

guests)
  unpack_archive
  for id in "${ORDER[@]}"; do
    if exists "$id"; then echo "   ${id}: exists, skipped"; continue; fi
    a="$(newest_archive "$id")"
    [ -n "$a" ] || { echo "   ${id}: NO ARCHIVE, skipped" >&2; continue; }
    info "restore ${id} from ${a}"
    if [ "$(guest_type "$a")" = lxc ]; then
      pct restore "$id" "${BACKUP_DIR}/${a}" --storage "$STORAGE" >/dev/null
    else
      qmrestore "${BACKUP_DIR}/${a}" "$id" --storage "$STORAGE" >/dev/null
      reattach_disks "$id" qemu
    fi
  done
  info "starting in order"
  for id in "${ORDER[@]}"; do
    exists "$id" || continue
    if qm status "$id" >/dev/null 2>&1; then qm start "$id" 2>/dev/null || true; else pct start "$id" 2>/dev/null || true; fi
    # vm102 serves the shares the next guests bind: wait until the host's
    # automounts answer before going on.
    if [ "$id" = 102 ]; then
      for _ in $(seq 1 40); do ls /mnt/smb/postgres-backups >/dev/null 2>&1 && break; sleep 5; done
    fi
  done
  info "guests done; run 'verify'"
  ;;

verify)
  qm list; pct list
  echo
  echo "Left to do, in this order:"
  echo " 1. from lxc250: every playbook that targets the proxmox group, so the host's"
  echo "    roles (node_exporter, guest_backup, lan_guard, homelab_schedule, ...) own it again"
  echo " 2. from lxc250: fleet-health-check.yml and a drift sweep"
  echo " 3. confirm on the Tailscale console that no second 'server' node appeared"
  ;;
esac
