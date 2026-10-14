#!/usr/bin/env bash
#
# Nightly pg_dumpall of the whole cluster onto the SMB backup share.
# Deployed by the postgresql_backup role; edit this file, never the node copy.
# snippets/postgres/pg-restore-test.sh restores the newest dump monthly.

set -euo pipefail

# === Configuration ===
BACKUP_DIR="/mnt/backups"
RETENTION_DAYS=7
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
DUMP_FILE="${BACKUP_DIR}/pg_dumpall_${TIMESTAMP}.sql.gz"

# Written here and renamed to DUMP_FILE only once read back and found complete.
# Writing straight to the real name would leave an aborted run's remains where
# the restore test and a recovery select "the newest dump".
PARTIAL_FILE="${DUMP_FILE}.partial"

TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"

# === Pre-flight checks ===
# Test the mount's identity, not that the path exists: /mnt/backups is a bind of
# the host's CIFS mount of //vm102/Postgres-Backups, and without it the dump
# would fill the thin pool on the boot SSD. See KE-7 and KE-15.
FSTYPE="$(findmnt -no FSTYPE "$BACKUP_DIR" 2>/dev/null || true)"
if [ "$FSTYPE" != "cifs" ]; then
  echo "ERROR: ${BACKUP_DIR} is not a CIFS mount (fstype='${FSTYPE:-none}') - refusing to dump onto local disk" >&2
  exit 1
fi

# === Dump all databases + roles ===
pg_dumpall | gzip > "$PARTIAL_FILE"

# === Verify the dump before anything depends on it ===
#
# Runs before the retention cleanup on purpose: retention (7 days) is shorter
# than the monthly restore test's detection window, so no old dump is deleted
# until the new one is proven readable.
#
# The read-back is served from the CIFS page cache (cache=strict): this proves
# the stream is complete, not that it is durable on vm102. The monthly restore
# test covers durability.

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

# 3. Logical completeness, which gzip -t cannot see: a killed pg_dumpall is
#    still a valid gzip and restores without error into empty tables. Only the
#    trailer pg_dumpall writes as its last line separates finished from truncated.
#    `grep -c` reads to EOF, so no SIGPIPE under pipefail; `|| true` covers
#    grep's exit 1 on zero matches.
MARKERS="$(gzip -cd "$PARTIAL_FILE" | grep -c 'PostgreSQL database cluster dump complete' || true)"
if [ "$MARKERS" -ne 1 ]; then
  echo "ERROR: dump carries ${MARKERS} completion markers, expected 1 - truncated: ${PARTIAL_FILE}" >&2
  exit 1
fi

# === Publish under the real name ===
# Rename within one directory, so no half-written dump appears under a selected
# name. A failed run leaves its .partial file as diagnostic evidence; it does not
# match the restore glob and ages out through the retention rule below.
mv "$PARTIAL_FILE" "$DUMP_FILE"

# === Retention cleanup ===
# Both names, so .partial files cannot accumulate. -maxdepth 1 and -type f keep
# the delete rule inside this directory.
find "$BACKUP_DIR" -maxdepth 1 -type f \
     \( -name 'pg_dumpall_*.sql.gz' -o -name 'pg_dumpall_*.sql.gz.partial' \) \
     -mtime "+${RETENTION_DAYS}" -delete

# === Textfile collector metric (Prometheus backup staleness alert) ===
# Reached only after every check passed: the metric means "a verified dump
# exists", not "the script ran".
if [ -d "$TEXTFILE_DIR" ]; then
  echo "pg_backup_last_success_timestamp $(date +%s)" > "${TEXTFILE_DIR}/pg_backup.prom"
fi

# === Summary ===
SIZE="$(du -h "$DUMP_FILE" | cut -f1)"
echo "OK: ${DUMP_FILE} (${SIZE}), gzip and completion marker verified"
