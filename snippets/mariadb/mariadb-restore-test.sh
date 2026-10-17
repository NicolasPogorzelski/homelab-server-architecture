#!/usr/bin/env bash
#
# Monthly proof that the newest MariaDB dump on the SMB share restores.
# Deployed by the mariadb_restore_test role; edit this file, never the node copy.
#
# Differs from pg-restore-test.sh because of the data model: pg_dumpall is
# cluster-wide and needs a second cluster, mariadb-dump writes databases, so the
# throwaway is a scratch database beside the live one on the same server. The
# safety of the whole test rests on the scratch name never being a live one.
set -euo pipefail

# === Configuration ===
BACKUP_DIR="/mnt/backups"

# The throwaway. Anything restored lands here and nowhere else, and the guard
# below refuses to run if a database of this name is one the live instance uses.
TEST_DB="restoretest_scratch"

# The database inside the dump whose section is extracted. The dump is an
# --all-databases dump, so it also carries `mysql` with every account and grant -
# which is right for a real restore and must never reach a scratch database.
SOURCE_DB="nextcloud"

TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
METRIC_FILE="${TEXTFILE_DIR}/mariadb_restore_test.prom"

# Skip a dump younger than this, so an overlapping backup run cannot offer a
# file still being written and cause a false alarm.
DUMP_MIN_AGE_MIN=5

# Tables asserted non-empty: Nextcloud cannot serve a file without them.
# oc_storages maps storage id to mount, oc_mounts ties it to a user, oc_filecache
# turns a blob on disk back into a path.
EXPECTED_TABLES=(
    "oc_storages"
    "oc_mounts"
    "oc_filecache"
)

# MariaDB 10.11 ships `mariadb`; `mysql` is a compatibility symlink upstream
# intends to drop. Fall back so an older node still works.
CLIENT_BIN="$(command -v mariadb || command -v mysql)"

# === Helpers ===
sql() {
    "${CLIENT_BIN}" --batch --skip-column-names --execute "$1"
}

# Runs on every exit path, so an aborted run cannot leave the scratch database
# behind.
cleanup() {
    sql "DROP DATABASE IF EXISTS \`${TEST_DB}\`;" >/dev/null 2>&1 \
        || echo "WARNING: could not drop ${TEST_DB} - remove it by hand" >&2
}
# Re-armed later with the import log added, once that file exists.
trap cleanup EXIT

# === Pre-flight: the scratch name must not be a live database ===
# A TEST_DB that named `nextcloud` would drop the production database on the
# trap above.
if sql "SHOW DATABASES;" | grep -qx "${TEST_DB}"; then
    echo "ERROR: ${TEST_DB} already exists - refusing to reuse a database this script will drop" >&2
    exit 1
fi

# === Pre-flight: is the backup share actually mounted? ===
# Identity, not existence: without the CIFS mount the bind target still exists
# and the run would fail with a misleading "no dump" message. See KE-15.
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

# A truncated dump is still a valid gzip; only the completion marker shows it.
MARKERS="$(gzip -cd "${DUMP}" | grep -c 'Dump completed' || true)"
if [ "${MARKERS}" -ne 1 ]; then
    echo "ERROR: ${DUMP} carries ${MARKERS} completion markers, expected 1 - truncated dump" >&2
    exit 1
fi

# === Restore into the throwaway ===
#
# Not `--one-database`: it filters by the stream's own `USE` statements, so with
# "${TEST_DB}" it imports nothing and exits 0, and with "${SOURCE_DB}" it would
# restore over the LIVE database. Instead sed cuts the section from the source
# database's `USE` line to the next `USE` line and the client gets the scratch
# database as default. `CREATE DATABASE` and the `mysql` database are skipped.
sql "CREATE DATABASE \`${TEST_DB}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"

# The section depends on the dump's session preamble (SET NAMES, disabled
# FOREIGN_KEY_CHECKS, saved @OLD_TIME_ZONE); without it the import fails on
# four-byte characters, forward foreign keys and the time_zone reset. So the
# header up to the first CREATE DATABASE line is prepended. utf8mb4 is still set
# on the client because the connection charset is negotiated before the first
# statement is read.
IMPORT_LOG="$(mktemp)"
trap 'rm -f "${IMPORT_LOG}"; cleanup' EXIT

if ! { gzip -cd "${DUMP}" | sed -n '1,/^CREATE DATABASE/{ /^CREATE DATABASE/!p; }';
       gzip -cd "${DUMP}" \
       | sed -n "/^USE \`${SOURCE_DB}\`;\$/,/^USE \`/{ /^USE \`/d; p; }"; } \
     | "${CLIENT_BIN}" --default-character-set=utf8mb4 "${TEST_DB}" \
       > "${IMPORT_LOG}" 2>&1; then
    echo "ERROR: restore failed - the client exited non-zero" >&2
    # Only the ERROR lines: on a failed statement the client echoes the offending
    # row, which is user content and must not reach the persistent journal.
    grep '^ERROR' "${IMPORT_LOG}" | head -3 >&2 || true
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
# A failed run raises SystemdUnitFailed; a run that never happens is caught by
# MariaDBRestoreTestStale, which reads this timestamp.
if [ -d "${TEXTFILE_DIR}" ]; then
    printf 'mariadb_restore_test_last_success_timestamp %s\n' "$(date +%s)" > "${METRIC_FILE}"
fi

echo "OK: ${DUMP} restored and verified"
