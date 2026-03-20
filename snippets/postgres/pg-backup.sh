#!/usr/bin/env bash
set -euo pipefail

# === Configuration ===
BACKUP_DIR="/mnt/backups"
RETENTION_DAYS=7
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
DUMP_FILE="${BACKUP_DIR}/pg_dumpall_${TIMESTAMP}.sql.gz"

# === Pre-flight checks ===
if [ ! -d "$BACKUP_DIR" ]; then
  echo "ERROR: Backup directory ${BACKUP_DIR} does not exist" >&2
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

# === Summary ===
SIZE="$(du -h "$DUMP_FILE" | cut -f1)"
echo "OK: ${DUMP_FILE} (${SIZE})"
