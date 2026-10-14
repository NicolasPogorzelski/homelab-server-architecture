#!/usr/bin/env bash
#
# Nightly dump of the MariaDB instance on lxc210 (Nextcloud) onto the SMB backup
# share. Deployed by the mariadb_backup role; edit this file, never the node copy.
#
# Nextcloud's user files live on the archive pool, its database only on the boot
# SSD. Without the database the files are opaque blobs with no owner, name or
# share, so this dump is what makes the file backup restorable.
#
# Structure mirrors snippets/postgres/pg-backup.sh; differences are commented.

set -euo pipefail

# === Configuration ===
BACKUP_DIR="/mnt/backups"
RETENTION_DAYS=7
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
DUMP_FILE="${BACKUP_DIR}/mariadb_all_${TIMESTAMP}.sql.gz"

# Written under .partial and renamed only once proven complete, so nothing ever
# selects a half-written dump as the newest one (same reasoning as pg-backup.sh).
PARTIAL_FILE="${DUMP_FILE}.partial"

TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"

# MariaDB 10.11 ships `mariadb-dump`; `mysqldump` is a compatibility symlink
# upstream intends to drop. Fall back so an older node still works.
DUMP_BIN="$(command -v mariadb-dump || command -v mysqldump)"

# === Pre-flight checks ===
# Test the mount's identity, not that the path exists: without the CIFS mount the
# bind target still exists and the dump would fill the thin pool on the boot SSD.
# See KE-7 and KE-15.
FSTYPE="$(findmnt -no FSTYPE "$BACKUP_DIR" 2>/dev/null || true)"
if [ "$FSTYPE" != "cifs" ]; then
  echo "ERROR: ${BACKUP_DIR} is not a CIFS mount (fstype='${FSTYPE:-none}') - refusing to dump onto local disk" >&2
  exit 1
fi

# === Dump every database, plus users and grants ===
#
# --all-databases       includes `mysql`, so users and grants come back with the
#                       data (the analogue of pg_dumpall carrying roles).
# --single-transaction  consistent read view instead of table locks. All
#                       nextcloud tables are InnoDB; the non-transactional
#                       `mysql` tables change only when an account changes.
# --quick               streams row by row instead of buffering whole tables.
# --routines --triggers --events
#                       stored programs are schema; without them a restored
#                       database looks complete and misbehaves.
# --default-character-set=utf8mb4
#                       Nextcloud stores utf8mb4; another connection charset
#                       would silently transcode filenames.
"$DUMP_BIN" \
  --all-databases \
  --single-transaction \
  --quick \
  --routines \
  --triggers \
  --events \
  --default-character-set=utf8mb4 \
  | gzip > "$PARTIAL_FILE"

# === Verify the dump before anything depends on it ===
#
# Runs before the retention cleanup on purpose: no old dump is deleted until the
# new one is proven readable. The read-back is served from the CIFS page cache,
# so this proves the stream is complete, not that it is durable on vm102.

# 1. Non-empty.
if [ ! -s "$PARTIAL_FILE" ]; then
  echo "ERROR: dump is empty: ${PARTIAL_FILE}" >&2
  exit 1
fi

# 2. gzip -t verifies CRC32 and the ISIZE trailer: truncation and bit flips fail.
if ! gzip -t "$PARTIAL_FILE"; then
  echo "ERROR: dump fails the gzip integrity check: ${PARTIAL_FILE}" >&2
  exit 1
fi

# 3. Logical completeness, which gzip -t cannot see: a killed dump is still a
#    valid gzip and restores without error into a database missing rows.
#    mariadb-dump writes `-- Dump completed on <timestamp>` as its last line
#    unless --skip-dump-date is given (it is not). `grep -c` reads to EOF, so no
#    SIGPIPE under pipefail; `|| true` covers grep's exit 1 on zero matches.
MARKERS="$(gzip -cd "$PARTIAL_FILE" | grep -c '^-- Dump completed on ' || true)"
if [ "$MARKERS" -ne 1 ]; then
  echo "ERROR: dump carries ${MARKERS} completion markers, expected 1 - truncated: ${PARTIAL_FILE}" >&2
  exit 1
fi

# === Publish under the real name ===
# A failed run leaves its .partial file as diagnostic evidence; it does not match
# the recovery glob and ages out through the retention rule below.
mv "$PARTIAL_FILE" "$DUMP_FILE"

# === Retention cleanup ===
# Both names, so .partial files cannot accumulate. `-mtime +7` means 7 days of
# age (effectively 8), not 7 dumps: nights the host stays off produce no dump.
find "$BACKUP_DIR" -maxdepth 1 -type f \
     \( -name 'mariadb_all_*.sql.gz' -o -name 'mariadb_all_*.sql.gz.partial' \) \
     -mtime "+${RETENTION_DAYS}" -delete

# === Textfile collector metric (Prometheus backup staleness alert) ===
# Reached only after every check passed: the metric means "a verified dump
# exists", not "the script ran".
if [ -d "$TEXTFILE_DIR" ]; then
  echo "mariadb_backup_last_success_timestamp $(date +%s)" > "${TEXTFILE_DIR}/mariadb_backup.prom"
fi

# === Summary ===
SIZE="$(du -h "$DUMP_FILE" | cut -f1)"
echo "OK: ${DUMP_FILE} (${SIZE}), gzip and completion marker verified"
