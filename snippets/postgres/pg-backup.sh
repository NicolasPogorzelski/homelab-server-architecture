#!/usr/bin/env bash
set -euo pipefail

# === Configuration ===
BACKUP_DIR="/mnt/backups"
RETENTION_DAYS=7
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
DUMP_FILE="${BACKUP_DIR}/pg_dumpall_${TIMESTAMP}.sql.gz"

# === Pre-flight checks ===
# Test the mount's identity, not merely that the path exists. /mnt/backups is a
# bind of the host's CIFS mount of //vm102/Postgres-Backups. If that mount is
# absent, the mountpoint directory still exists and `[ -d ]` passes — pg_dumpall
# would then write ~42 MB per night into the container rootfs, i.e. into the thin
# pool on the boot SSD, until it fills. That is the KE-7 failure class, and it is
# the same mistake `mountpoint -q` made in calibre-import.sh (KE-15).
FSTYPE="$(findmnt -no FSTYPE "$BACKUP_DIR" 2>/dev/null || true)"
if [ "$FSTYPE" != "cifs" ]; then
  echo "ERROR: ${BACKUP_DIR} is not a CIFS mount (fstype='${FSTYPE:-none}') — refusing to dump onto local disk" >&2
  exit 1
fi

# === Dump all databases + roles ===
pg_dumpall | gzip > "$DUMP_FILE"

# === Verify dump is non-empty ===
if [ ! -s "$DUMP_FILE" ]; then
  echo "ERROR: Dump file is empty: ${DUMP_FILE}" >&2
  exit 1
fi

# === Retention cleanup ===
find "$BACKUP_DIR" -name "pg_dumpall_*.sql.gz" -mtime +${RETENTION_DAYS} -delete

# === Textfile collector metric (Prometheus backup staleness alert) ===
TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
if [ -d "$TEXTFILE_DIR" ]; then
  echo "pg_backup_last_success_timestamp $(date +%s)" > "${TEXTFILE_DIR}/pg_backup.prom"
fi

# === Summary ===
SIZE="$(du -h "$DUMP_FILE" | cut -f1)"
echo "OK: ${DUMP_FILE} (${SIZE})"
