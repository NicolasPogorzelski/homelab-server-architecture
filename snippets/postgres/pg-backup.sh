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

# === Textfile collector metric (Prometheus backup staleness alert) ===
TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
if [ -d "$TEXTFILE_DIR" ]; then
  echo "pg_backup_last_success_timestamp $(date +%s)" > "${TEXTFILE_DIR}/pg_backup.prom"
fi

# === Summary ===
SIZE="$(du -h "$DUMP_FILE" | cut -f1)"
echo "OK: ${DUMP_FILE} (${SIZE})"
