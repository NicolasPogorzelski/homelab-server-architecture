#!/usr/bin/env bash
#
# Monthly proof that the MariaDB dump on the SMB share can be read back.
#
# Deployed by the mariadb_restore_test role. Edit this file, never the copy on
# the node.
#
# Why it exists: the dump has run nightly since 2026-08-15 with write-time
# verification, a staleness rule and a runbook, and until 2026-09-17 nobody had
# ever restored one. PostgreSQL has carried all of that plus a monthly restore
# since 2026-08-13; this is the half of Nextcloud that makes its files mean
# something, and a dump nobody has restored is an assumption rather than a
# backup.
#
# It differs from pg-restore-test.sh in one structural way, and the difference is
# the data model rather than a preference. pg_dumpall is cluster-wide, so proving
# it needs a second cluster on a second port. mariadb-dump here writes databases,
# so the throwaway is a database beside the live one on the same server. That
# keeps the test cheap - the schema is some 38 MB - and puts the whole weight of
# the safety argument on one thing: the target name must never be a live one.
set -euo pipefail

# === Configuration ===
BACKUP_DIR="/mnt/backups"

# The throwaway. Anything restored lands here and nowhere else, and the guard
# below refuses to run if a database of this name is one the live instance uses.
TEST_DB="restoretest_scratch"

TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
METRIC_FILE="${TEXTFILE_DIR}/mariadb_restore_test.prom"

# Skip a dump younger than this. The nightly job renames into place only after
# its own checks pass, but a run that overlapped this one would otherwise offer a
# file still being written, and the integrity check would report a false alarm.
DUMP_MIN_AGE_MIN=5

# Tables asserted to come back non-empty. Chosen because Nextcloud cannot serve a
# single file without them: oc_storages maps a storage id to its mount, oc_mounts
# ties that to a user, and oc_filecache is the index that turns a blob on disk
# back into a path. A restore that produced empty versions of these would import
# without error and rebuild nothing.
EXPECTED_TABLES=(
    "oc_storages"
    "oc_mounts"
    "oc_filecache"
)

# MariaDB 10.11 ships mariadb/mariadb-dump; the mysql* names are compatibility
# symlinks upstream intends to drop. Prefer the real names, fall back so the
# script still works on an older node.
CLIENT_BIN="$(command -v mariadb || command -v mysql)"

# === Helpers ===
sql() {
    "${CLIENT_BIN}" --batch --skip-column-names --execute "$1"
}

# Runs on every exit path, including failures and signals, so an aborted run
# cannot leave the scratch database occupying space or confusing the next one.
cleanup() {
    sql "DROP DATABASE IF EXISTS \`${TEST_DB}\`;" >/dev/null 2>&1 \
        || echo "WARNING: could not drop ${TEST_DB} - remove it by hand" >&2
}
trap cleanup EXIT

# === Pre-flight: the scratch name must not be a live database ===
# The one assertion this whole design rests on. A typo that pointed TEST_DB at
# `nextcloud` would drop the production database on the trap above, which is a
# far worse outcome than never testing the restore at all.
if sql "SHOW DATABASES;" | grep -qx "${TEST_DB}"; then
    echo "ERROR: ${TEST_DB} already exists - refusing to reuse a database this script will drop" >&2
    exit 1
fi

# === Pre-flight: is the backup share actually mounted? ===
# Identity, not existence. /mnt/backups is a bind of the host's CIFS mount; with
# the mount absent the directory still exists, `find` returns nothing, and the
# run would fail with a confusing message instead of a true one.
FSTYPE="$(findmnt -no FSTYPE "${BACKUP_DIR}" 2>/dev/null || true)"
if [ "${FSTYPE}" != "cifs" ]; then
    echo "ERROR: ${BACKUP_DIR} is not a CIFS mount (fstype='${FSTYPE:-none}')" >&2
    exit 1
fi

# === Select the newest settled dump ===
DUMP="$(find "${BACKUP_DIR}" -maxdepth 1 -type f -name 'mariadb_all_*.sql.gz' \
        -mmin "+${DUMP_MIN_AGE_MIN}" -printf '%T@ %p\n' | sort -nr | head -1 | cut -d' ' -f2-)"

if [ -z "${DUMP}" ]; then
    echo "ERROR: no dump older than ${DUMP_MIN_AGE_MIN} min in ${BACKUP_DIR}" >&2
    exit 1
fi
echo "selected dump: ${DUMP}"

# === Integrity: can the file be read back at all? ===
if ! gzip -t "${DUMP}"; then
    echo "ERROR: ${DUMP} fails the gzip integrity check" >&2
    exit 1
fi

# A valid gzip of a half-finished dump decompresses cleanly and imports into
# empty tables, which is the one failure the size and gzip checks both miss.
MARKERS="$(gzip -cd "${DUMP}" | grep -c 'Dump completed' || true)"
if [ "${MARKERS}" -ne 1 ]; then
    echo "ERROR: ${DUMP} carries ${MARKERS} completion markers, expected 1 - truncated dump" >&2
    exit 1
fi

# === Restore into the throwaway ===
# --one-database confines the stream: the dump carries `USE \`nextcloud\`;` and
# without this flag the import would write straight into the live database. The
# flag filters by the name given on the command line, so the statements for every
# other database in the file are discarded rather than applied.
sql "CREATE DATABASE \`${TEST_DB}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"

if ! gzip -cd "${DUMP}" | "${CLIENT_BIN}" --one-database "${TEST_DB}"; then
    echo "ERROR: restore failed - the client exited non-zero" >&2
    exit 1
fi

# === Assert the restored content ===
for table in "${EXPECTED_TABLES[@]}"; do
    rows="$(sql "SELECT count(*) FROM \`${TEST_DB}\`.\`${table}\`;" 2>/dev/null || true)"
    if ! [[ "${rows}" =~ ^[0-9]+$ ]] || [ "${rows}" -eq 0 ]; then
        echo "ERROR: ${TEST_DB}.${table} restored with '${rows:-no}' rows" >&2
        exit 1
    fi
    echo "ok: ${table} = ${rows} rows"
done

# === Publish the result ===
# A failed run raises SystemdUnitFailed. A run that never happens raises nothing,
# which is what MariaDBRestoreTestStale reads this timestamp for.
if [ -d "${TEXTFILE_DIR}" ]; then
    printf 'mariadb_restore_test_last_success_timestamp %s\n' "$(date +%s)" > "${METRIC_FILE}"
fi

echo "OK: ${DUMP} restored and verified"
