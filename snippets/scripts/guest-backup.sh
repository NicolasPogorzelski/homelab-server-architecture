#!/usr/bin/env bash
#
# Full guest backup of every VM and LXC on the Proxmox host, via vzdump.
#
# Deployed by the guest_backup role; edit this file, never the node copy.
#
# The database dumps restore data into a machine that already exists, and Ansible
# restores configuration; state such as Paperless' index, Grafana's dashboards
# and Nextcloud's app configuration is in neither. All 9 guest root disks share
# one thin pool on the boot SSD (KE-14), so they share one failure domain.
# Restore procedure: runbooks/platform/guest-backup-restore.md.

set -euo pipefail

# === Configuration ===

# A generic mountpoint, not the physical target: swapping the backup disk is an
# fstab change, and the real disk label stays out of the public repository.
BACKUP_DIR="/mnt/vzdump"

# Guests to back up, most valuable first, so an aborted run still has the
# irreplaceable ones. lxc250 leads: it holds the only copy of the real inventory
# and the Ansible SSH key. vm100 contributes its root disk only; its data disk
# carries `backup=0`, and the size guard below refuses the guest if that flag is
# ever lost. This list is a hand-maintained copy of `qm list` / `pct list`:
# recheck it when the fleet changes.
GUESTS=(250 260 210 211 200 220 230 102 100)

# Keep counts are per class, in time: keep-weekly=8 is eight weeks, not eight
# files.
PRUNE="keep-daily=3,keep-weekly=8,keep-monthly=6"

# A VM disk larger than this without `backup=0` stops that guest's backup. The
# passthrough disks of vm102 are terabytes each and vm100's data disk is 300 GB;
# one lost flag would otherwise fill the target in a single run.
MAX_DISK_GB=128

# zstd: about gzip's ratio at several times the speed; the run happens while the
# host is in use.
COMPRESS="zstd"

TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
PROM_FILE="${TEXTFILE_DIR}/guest-backup.prom"

# === Metrics ===
#
# Written whether the run succeeded or not, so "failed" and "never ran" stay
# distinguishable. They prove a run happened and how it ended, not that the
# archives restore; that is runbooks/platform/guest-backup-restore.md.

START_TS="$(date +%s)"
FAILED=0
DONE=0
METRICS_WRITTEN=0

write_metrics() {  # $1 = number of guests not backed up
  local end tmp bytes
  end="$(date +%s)"
  mkdir -p "$TEXTFILE_DIR"
  tmp="$(mktemp "${PROM_FILE}.XXXXXX")"
  bytes="$(du -sb "$BACKUP_DIR" 2>/dev/null | cut -f1 || echo 0)"
  cat > "$tmp" <<METRICS
# HELP guest_backup_last_run_timestamp_seconds Unix time at which the last guest backup run finished.
# TYPE guest_backup_last_run_timestamp_seconds gauge
guest_backup_last_run_timestamp_seconds ${end}
# HELP guest_backup_duration_seconds Wall-clock duration of the last guest backup run.
# TYPE guest_backup_duration_seconds gauge
guest_backup_duration_seconds $((end - START_TS))
# HELP guest_backup_failed_guests Number of guests the last run did not back up.
# TYPE guest_backup_failed_guests gauge
guest_backup_failed_guests ${1}
# HELP guest_backup_total_bytes Size of the backup target directory after the last run.
# TYPE guest_backup_total_bytes gauge
guest_backup_total_bytes ${bytes:-0}
METRICS
  chmod 0644 "$tmp"
  mv "$tmp" "$PROM_FILE" || rm -f "$tmp"
  METRICS_WRITTEN=1
}

# A run that ends early (failed pre-flight, an error under set -e, the nightly
# shutdown stopping the unit) would otherwise leave the previous metric in place
# and hide from GuestBackupPartial: every unfinished guest counts as failed. bash
# runs no EXIT trap on a fatal signal, so TERM and INT become an ordinary exit.
on_exit() {
  local rc=$?
  if [ "$METRICS_WRITTEN" -eq 0 ]; then
    write_metrics "$(( ${#GUESTS[@]} - DONE ))" || true
  fi
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# === Pre-flight checks ===

# Test the mount, not the path: without the backup disk, /mnt/vzdump is an empty
# directory on pve-root and vzdump would fill the boot SSD that carries every
# guest. See KE-7.
if ! mountpoint -q "$BACKUP_DIR"; then
  echo "ERROR: ${BACKUP_DIR} is not a mountpoint - refusing to write backups onto the root filesystem" >&2
  exit 1
fi

# A mountpoint on the same device as / would satisfy the check above and still be
# the wrong disk (a bind mount of a local directory, for instance). Compare the
# backing device instead.
ROOT_SRC="$(findmnt -no SOURCE / || true)"
DEST_SRC="$(findmnt -no SOURCE "$BACKUP_DIR" || true)"
if [ -z "$DEST_SRC" ] || [ "$DEST_SRC" = "$ROOT_SRC" ]; then
  echo "ERROR: ${BACKUP_DIR} resolves to the root device (${DEST_SRC:-none}) - refusing to write guest backups onto the disk that carries the guests" >&2
  exit 1
fi

# === Run ===

# Prints the disks of a VM that vzdump would include and that exceed MAX_DISK_GB.
oversized_disks() {
  qm config "$1" 2>/dev/null \
    | { grep -E '^(scsi|sata|virtio|ide)[0-9]+: ' || true; } | { grep -v -e 'media=cdrom' -e 'backup=0' || true; } \
    | while IFS= read -r line; do
        size="$(sed -nE 's/.*size=([0-9]+)([GMT]).*/\1 \2/p' <<<"$line")"
        [ -n "$size" ] || continue
        read -r n unit <<<"$size"
        case "$unit" in M) n=$((n / 1024)) ;; T) n=$((n * 1024)) ;; esac
        if [ "$n" -gt "$MAX_DISK_GB" ]; then echo "${line%%:*}"; fi
      done
  # A VM with no disk over the limit is the normal case, not a failure; under
  # set -e and pipefail a non-zero status here would end the whole run.
  return 0
}

for id in "${GUESTS[@]}"; do
  echo "=== vzdump ${id} ==="
  if [ -f "/etc/pve/qemu-server/${id}.conf" ]; then
    big="$(oversized_disks "$id" | tr '\n' ' ')"
    if [ -n "$big" ]; then
      echo "ERROR: VM ${id} would include ${big}over ${MAX_DISK_GB} GB without backup=0 - skipped" >&2
      FAILED=$((FAILED + 1))
      continue
    fi
  fi
  # --mode snapshot keeps the guest running; `stop` takes it down and `suspend`
  # freezes it for the whole run.
  #
  # A failing guest must not abort the loop and sacrifice every guest after it:
  # `set -e` is suspended for the call and the failure recorded instead.
  #
  # No --notes-template or --protected: vzdump declares both with
  # `requires => 'storage'`, so either fails parameter verification alongside
  # --dumpdir before any guest is touched.
  set +e
  vzdump "$id" \
    --mode snapshot \
    --compress "$COMPRESS" \
    --dumpdir "$BACKUP_DIR" \
    --prune-backups "$PRUNE"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "WARNING: vzdump ${id} exited ${rc}" >&2
    FAILED=$((FAILED + 1))
  else
    DONE=$((DONE + 1))
  fi
done

write_metrics "$FAILED"

# A non-zero exit puts the unit into `failed`, which SystemdUnitFailed reports.
# The metric above covers the case this cannot: a run that never starts.
if [ "$FAILED" -gt 0 ]; then
  echo "ERROR: ${FAILED} guest(s) failed to back up" >&2
  exit 1
fi

echo "All ${#GUESTS[@]} guests backed up to ${BACKUP_DIR}"
