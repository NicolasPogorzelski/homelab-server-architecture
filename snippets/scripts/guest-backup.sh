#!/usr/bin/env bash
#
# Full guest backup of every VM and LXC on the Proxmox host, via vzdump.
#
# Deployed by the guest_backup role. Edit this file, never the copy on the node.
#
# Why this exists: measured 2026-08-20, the platform had no guest backup at all.
# /etc/pve/jobs.cfg did not exist, the vzdump cron file held no entry, and the
# only artefacts in the dump directory were two log files from February. Eleven
# machines, none of them recoverable.
#
# The gap survived so long because the backups that DO exist look like coverage.
# pg-backup.sh and mariadb-backup.sh run nightly and are alerted on, so the word
# "backup" was answered. But a database dump restores data into a machine; it
# does not produce the machine. Ansible produces configuration, not state -
# Paperless' document index, Grafana's dashboards and its first-boot admin
# password, Nextcloud's app configuration are none of them in a role. And every
# guest root disk lives in one thin pool on one six-year-old SSD behind an HBA
# with unexplained boot-time I/O errors (KE-14). That is a single failure domain
# for the whole platform.
#
# The sharper evidence is runbooks/platform/lxc250-rebuild.md: a rebuild runbook
# exists precisely because there is no restore path. This script is what turns
# that rebuild into a restore.

set -euo pipefail

# === Configuration ===

# A generic mountpoint, deliberately not the physical target. The host binds
# whatever disk is currently in that role onto this path, so migrating from the
# interim disk to the replacement hardware is an fstab change and not a code
# change. It also keeps the real disk label out of a public repository, the same
# reason /etc/snapraid.conf's device lines stay hand-written.
BACKUP_DIR="/mnt/vzdump"

# Guests to back up, most-valuable first so that a run aborted halfway still
# leaves the irreplaceable ones done. lxc250 leads: it is the control node, and
# it holds the only copy of the real inventory and the Ansible SSH key.
#
# VM100 is absent on purpose, not by oversight. It is 25 GB of root plus 18 GB of
# Jellyfin metadata and transcoding cache, all of it reproducible from the compose
# stack in minutes, and its media lives on vm102. Including it would roughly
# triple the size of a run to protect the one guest that needs it least.
GUESTS=(250 260 210 211 200 220 230 102)

# Retention is expressed in time, not in a number of files. The distinction is
# not pedantic: the PostgreSQL retention reads `-mtime +7`, which means seven
# DAYS, so on a host that sleeps at night a week of failures leaves nothing
# behind. vzdump's own pruner takes the same shape - these keep counts are
# per-class, so keep-weekly=8 is eight weeks, not eight files.
PRUNE="keep-daily=3,keep-weekly=8,keep-monthly=6"

# zstd, not gzip or lzo. It reaches roughly the same ratio as gzip at several
# times the speed, and the run happens while the host is awake and in use.
COMPRESS="zstd"

TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
PROM_FILE="${TEXTFILE_DIR}/guest-backup.prom"

# === Pre-flight checks ===

# Test the mount's identity, not merely that the path exists.
#
# This is the KE-7 failure class and it is why the check is first. If the backup
# disk fails to mount, /mnt/vzdump still exists as an empty directory on
# pve-root, `[ -d ]` passes, and vzdump happily writes ten gigabytes per run into
# the thin pool on the boot SSD - filling the disk that carries every guest, in
# order to back up those guests. The `appdata` storage had exactly this defect
# until `is_mountpoint 1` was set on 2026-08-17.
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
  echo "ERROR: ${BACKUP_DIR} resolves to the root device (${DEST_SRC:-none}) - a backup there shares the failure domain it exists to survive" >&2
  exit 1
fi

# === Run ===

START_TS="$(date +%s)"
FAILED=0

for id in "${GUESTS[@]}"; do
  echo "=== vzdump ${id} ==="
  # --mode snapshot takes an LVM-thin snapshot and backs that up, so the guest
  # keeps running. `stop` would be consistent but takes the platform down once a
  # week; `suspend` freezes the guest for the whole run. Snapshot is the only one
  # of the three that is compatible with a host somebody is using.
  #
  # A failing guest must not abort the loop: the guests are ordered by value, and
  # stopping at the first error would sacrifice every guest after it to a fault
  # in one. `set -e` is suspended for the call and the failure recorded instead.
  set +e
  vzdump "$id" \
    --mode snapshot \
    --compress "$COMPRESS" \
    --dumpdir "$BACKUP_DIR" \
    --prune-backups "$PRUNE" \
    --notes-template '{{guestname}} {{node}}'
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "WARNING: vzdump ${id} exited ${rc}" >&2
    FAILED=$((FAILED + 1))
  fi
done

END_TS="$(date +%s)"

# === Metrics ===
#
# Written whether the run succeeded or not, and written last. A collector that
# only emits on success cannot distinguish "failed" from "never ran", which is
# the same blindness LvmThinMetricsStale was added to cover.
#
# Note what these metrics can and cannot see. They prove a run happened and how
# it ended. They do not prove the archives are restorable - only an actual
# restore does that, which is why runbooks/platform/guest-backup-restore.md
# carries a recorded-date discipline, the same one pg-restore.md uses.
mkdir -p "$TEXTFILE_DIR"
TMPFILE="$(mktemp "${PROM_FILE}.XXXXXX")"
# The predecessor SMART collector has no such trap and leaked eleven temp files
# into this directory between 2025-12 and 2026-08.
trap 'rm -f "$TMPFILE"' EXIT

BYTES="$(du -sb "$BACKUP_DIR" 2>/dev/null | cut -f1 || echo 0)"

cat > "$TMPFILE" <<METRICS
# HELP guest_backup_last_run_timestamp_seconds Unix time at which the last guest backup run finished.
# TYPE guest_backup_last_run_timestamp_seconds gauge
guest_backup_last_run_timestamp_seconds ${END_TS}
# HELP guest_backup_duration_seconds Wall-clock duration of the last guest backup run.
# TYPE guest_backup_duration_seconds gauge
guest_backup_duration_seconds $((END_TS - START_TS))
# HELP guest_backup_failed_guests Number of guests whose vzdump exited non-zero in the last run.
# TYPE guest_backup_failed_guests gauge
guest_backup_failed_guests ${FAILED}
# HELP guest_backup_total_bytes Size of the backup target directory after the last run.
# TYPE guest_backup_total_bytes gauge
guest_backup_total_bytes ${BYTES}
METRICS

chmod 0644 "$TMPFILE"
mv "$TMPFILE" "$PROM_FILE"
trap - EXIT

# A non-zero exit puts the unit into `failed`, which SystemdUnitFailed reports.
# The metric above covers the case this cannot: a run that never starts.
if [ "$FAILED" -gt 0 ]; then
  echo "ERROR: ${FAILED} guest(s) failed to back up" >&2
  exit 1
fi

echo "All ${#GUESTS[@]} guests backed up to ${BACKUP_DIR}"
