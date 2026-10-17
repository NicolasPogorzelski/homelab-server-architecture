#!/usr/bin/env bash
#
# Backup of the Proxmox host's own configuration - the state no guest archive
# carries and no Ansible role reproduces.
#
# Deployed by the guest_backup role; edit this file, never the node copy.
#
# vzdump restores guests, not the host they expect: fstab entries, CIFS mounts
# and credentials, IOMMU arguments and vfio bindings, storage definitions, the
# Tailscale node identity and the units under /etc/systemd/system.
#
# One archive per run, written to the backup disk and the boot disk; either
# survives the loss of the other. Both are local: a restore aid, not an off-site
# copy. The archive holds secrets, so it is root-only on both.

set -euo pipefail

# === Configuration ===

# The generic backup mountpoint, as in guest-backup.sh, plus a directory on the
# root filesystem.
TARGETS=("/mnt/vzdump/host-config" "/var/backups/host-config")

# Archives kept per target. The configuration changes rarely, so fourteen daily
# runs cover the two weeks in which a bad change is most likely to be noticed.
KEEP=14

TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
PROM_FILE="${TEXTFILE_DIR}/host_config_backup.prom"

# What the archive contains, beside the metadata collected below. /etc holds
# /etc/pve as a FUSE view, so the guest and storage configuration come along as
# plain files; config.db is the database behind that view and is added as a
# consistent copy.
PATHS=(
  etc
  root/.ssh
  var/lib/tailscale
  usr/local
  usr/share/keyrings/tailscale-archive-keyring.gpg
)
# The daemon's own logs are large and say nothing a restore needs.
EXCLUDES=(--exclude='var/lib/tailscale/tailscaled.log*')

# === Run ===

# The backup target must be the mounted disk, never an empty directory on root;
# see the same guard in guest-backup.sh.
mountpoint -q /mnt/vzdump || { echo "ERROR: /mnt/vzdump is not mounted" >&2; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
NAME="host-config-$(hostname -s)-${STAMP}"
WORK="$(mktemp -d /var/tmp/host-config.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "${WORK}/meta"

# The cluster database through sqlite's own backup command, so a write by
# pmxcfs during the copy cannot leave a torn file.
sqlite3 /var/lib/pve-cluster/config.db ".backup '${WORK}/meta/config.db'"

# The CIFS credential files live directly in /root, named by convention.
cp -a /root/.smbcredentials-* "${WORK}/meta/" 2>/dev/null || true

# The guest configurations once more, flat and by ID. /etc/pve keeps them under
# nodes/<hostname>/, which a restore onto a host with another name would not
# find; platform-restore.sh reads them from here.
mkdir -p "${WORK}/meta/guest-conf"
cp /etc/pve/qemu-server/*.conf /etc/pve/lxc/*.conf "${WORK}/meta/guest-conf/" 2>/dev/null || true

# What the restore needs to know about this machine and cannot read from files:
# versions, packages, the disk identities the passthrough lines name, the LVM
# layout and the guest list.
# Each is best effort: a missing piece of metadata must not cost the archive.
M="${WORK}/meta"
pveversion -v            > "$M/pveversion.txt"      2>&1 || true
dpkg --get-selections    > "$M/dpkg-selections.txt" 2>&1 || true
apt-mark showmanual      > "$M/apt-manual.txt"      2>&1 || true
cat /proc/cmdline        > "$M/cmdline.txt"         2>&1 || true
ls -l /dev/disk/by-id/   > "$M/disk-by-id.txt"      2>&1 || true
lsblk -J -o NAME,SIZE,TYPE,MODEL,SERIAL,WWN,MOUNTPOINTS > "$M/lsblk.json" 2>&1 || true
{ pvs; vgs; lvs; }       > "$M/lvm.txt"             2>&1 || true
qm list                  > "$M/qm-list.txt"         2>&1 || true
pct list                 > "$M/pct-list.txt"        2>&1 || true
ip -br address           > "$M/ip.txt"              2>&1 || true

# Stored relative to /, so a member is named etc/fstab and extracts under any
# directory given to -C.
tar --create --zstd --file "${WORK}/${NAME}.tar.zst" \
  --ignore-failed-read "${EXCLUDES[@]}" \
  -C / "${PATHS[@]}" -C "${WORK}" meta
( cd "${WORK}" && sha256sum "${NAME}.tar.zst" > "${NAME}.tar.zst.sha256" )

BYTES="$(stat -c %s "${WORK}/${NAME}.tar.zst")"
for t in "${TARGETS[@]}"; do
  install -d -m 0700 "$t"
  install -m 0600 "${WORK}/${NAME}.tar.zst" "${WORK}/${NAME}.tar.zst.sha256" "$t/"
  # Newest KEEP archives stay, by name, which sorts by time.
  find "$t" -maxdepth 1 -name 'host-config-*.tar.zst' -printf '%f\n' \
    | sort -r | tail -n +$((KEEP + 1)) \
    | while read -r old; do rm -f "$t/$old" "$t/$old.sha256"; done
done

# === Metrics ===
mkdir -p "$TEXTFILE_DIR"
TMPFILE="$(mktemp "${PROM_FILE}.XXXXXX")"
cat > "$TMPFILE" <<METRICS
# HELP host_config_backup_last_success_timestamp_seconds Unix time of the last host configuration archive written to every target.
# TYPE host_config_backup_last_success_timestamp_seconds gauge
host_config_backup_last_success_timestamp_seconds $(date +%s)
# HELP host_config_backup_bytes Size of the last host configuration archive.
# TYPE host_config_backup_bytes gauge
host_config_backup_bytes ${BYTES}
METRICS
chmod 0644 "$TMPFILE"
mv "$TMPFILE" "$PROM_FILE"

echo "${NAME}.tar.zst (${BYTES} bytes) written to ${TARGETS[*]}"
