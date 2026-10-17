#!/usr/bin/env bash
#
# Validate that the newest pg_dumpall backup can be restored.
# Deployed by the postgresql_restore_test role; edit this file, never the node copy.
#
# Validation counterpart to runbooks/database/pg-restore.md, whose procedure
# drops a live database. Here nothing live is touched: the dump is restored into
# a throwaway cluster on a second port, asserted, and the cluster is destroyed.
#
# No comparison against the live database: append-only tables keep growing after
# the dump, so a live comparison would differ on every run. The dump is checked
# against itself: complete, restorable, and holding data.

set -euo pipefail

# === Configuration ===
BACKUP_DIR="/mnt/backups"
PG_VERSION="15"
TEST_CLUSTER="restoretest"
TEST_PORT="5433"

# Must match the live cluster (SELECT datcollate FROM pg_database): the dump's
# CREATE DATABASE ... LC_COLLATE fails against another locale, and the
# container's default is LANG=C.
TEST_LOCALE="en_US.UTF-8"

TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
METRIC_FILE="${TEXTFILE_DIR}/pg_restore_test.prom"

# Ignore dumps younger than this: after boot both timers may catch up at once,
# and a dump still being written would raise a false alarm.
DUMP_MIN_AGE_MIN=5

# "database:table" pairs that must exist and hold at least one row afterwards:
# the second defence, after the completion marker, against a dump truncated
# before its COPY blocks.
EXPECTED_TABLES=(
    "paperless_db:documents_document"
    "openwebui_db:migratehistory"
)

# Expected psql errors: pg_dumpall emits CREATE ROLE for every role, and the
# throwaway cluster already has its postgres superuser from initdb.
ERROR_ALLOWLIST='^ERROR:  role ".*" already exists$'

STDERR_LOG=""

# === Helpers ===

cluster_exists() {
    pg_lsclusters -h 2>/dev/null \
        | awk -v v="${PG_VERSION}" -v c="${TEST_CLUSTER}" \
              '$1 == v && $2 == c { found = 1 } END { exit !found }'
}

# Runs on every exit path so an aborted run cannot leave a cluster on the port.
# Each step is guarded so a failure in the trap keeps the real exit status.
cleanup() {
    if cluster_exists; then
        pg_dropcluster "${PG_VERSION}" "${TEST_CLUSTER}" --stop \
            || echo "WARNING: could not drop cluster ${TEST_CLUSTER} - remove it by hand" >&2
    fi
    [ -n "${STDERR_LOG}" ] && rm -f "${STDERR_LOG}"
    return 0
}
trap cleanup EXIT

# === Pre-flight: is the backup share actually mounted? ===
# Mount identity, not path existence: without the CIFS mount the bind target is
# empty and the run would report "no dumps" instead of "share unreachable".
# See KE-15.
FSTYPE="$(findmnt -no FSTYPE "${BACKUP_DIR}" 2>/dev/null || true)"
if [ "${FSTYPE}" != "cifs" ]; then
    echo "ERROR: ${BACKUP_DIR} is not a CIFS mount (fstype='${FSTYPE:-none}')" >&2
    exit 1
fi

# === Select the newest settled dump ===
# awk, not `head -1`: head closes the pipe early, which can SIGPIPE `sort` and
# fail the run under pipefail. sub() strips the sort key instead of using $2, so
# a path containing a space survives.
DUMP="$(find "${BACKUP_DIR}" -maxdepth 1 -type f -name 'pg_dumpall_*.sql.gz' \
        -mmin "+${DUMP_MIN_AGE_MIN}" -printf '%T@ %p\n' \
        | sort -rn | awk 'NR == 1 { sub(/^[^ ]+ /, ""); print }')"
if [ -z "${DUMP}" ]; then
    echo "ERROR: no dump older than ${DUMP_MIN_AGE_MIN} min in ${BACKUP_DIR}" >&2
    exit 1
fi
echo "selected dump: ${DUMP}"

# === Integrity: can the dump be read back at all? ===
# gzip -t proves the stream is intact, not that the dump is complete; only the
# trailer pg_dumpall writes last separates finished from truncated. pg-backup.sh
# checks both at write time; this re-checks the file as it is read today.
if ! gzip -t "${DUMP}"; then
    echo "ERROR: ${DUMP} fails the gzip integrity check" >&2
    exit 1
fi

MARKERS="$(gzip -cd "${DUMP}" | grep -c 'PostgreSQL database cluster dump complete' || true)"
if [ "${MARKERS}" -ne 1 ]; then
    echo "ERROR: ${DUMP} carries ${MARKERS} completion markers, expected 1 - truncated dump" >&2
    exit 1
fi

# === Remove a cluster left behind by an aborted earlier run ===
# Without this, one interrupted run makes every later run fail on the occupied
# port.
if cluster_exists; then
    echo "removing a stale ${TEST_CLUSTER} cluster from a previous run"
    pg_dropcluster "${PG_VERSION}" "${TEST_CLUSTER}" --stop
fi

# === Throwaway cluster ===
# --start-conf manual: a cluster left by a killed run must not start at boot.
pg_createcluster "${PG_VERSION}" "${TEST_CLUSTER}" \
    --port "${TEST_PORT}" --locale "${TEST_LOCALE}" --start-conf manual
pg_ctlcluster "${PG_VERSION}" "${TEST_CLUSTER}" start

# === Restore ===
# Every psql call carries --port: it alone separates this from production, so
# it is never defaulted. runuser drops to postgres because a fresh cluster
# authenticates local superuser connections by peer.
STDERR_LOG="$(mktemp)"
if ! gzip -cd "${DUMP}" \
        | runuser -u postgres -- psql --port "${TEST_PORT}" --quiet --dbname postgres \
          >/dev/null 2>"${STDERR_LOG}"; then
    echo "ERROR: restore failed - psql exited non-zero" >&2
    head -20 "${STDERR_LOG}" >&2
    exit 1
fi

# psql returns 0 when individual statements fail (no ON_ERROR_STOP, because the
# expected role collision would abort the restore), so stderr is classified too.
UNEXPECTED="$(grep '^ERROR:' "${STDERR_LOG}" | grep -Ev "${ERROR_ALLOWLIST}" || true)"
if [ -n "${UNEXPECTED}" ]; then
    echo "ERROR: restore produced unexpected errors:" >&2
    echo "${UNEXPECTED}" | head -20 >&2
    exit 1
fi

# === Assert the restored cluster holds data ===
for pair in "${EXPECTED_TABLES[@]}"; do
    db="${pair%%:*}"
    table="${pair##*:}"

    if ! runuser -u postgres -- psql --port "${TEST_PORT}" --list --tuples-only --no-align \
            | cut -d'|' -f1 | grep -qx "${db}"; then
        echo "ERROR: database ${db} is missing from the restored cluster" >&2
        exit 1
    fi

    # The identifier is double-quoted so reserved words survive as table names.
    rows="$(runuser -u postgres -- psql --port "${TEST_PORT}" --dbname "${db}" \
            --tuples-only --no-align --command "SELECT count(*) FROM \"${table}\";")"

    if ! [[ "${rows}" =~ ^[0-9]+$ ]] || [ "${rows}" -eq 0 ]; then
        echo "ERROR: ${db}.${table} restored with '${rows:-no}' rows" >&2
        exit 1
    fi
    echo "ok: ${db}.${table} = ${rows} rows"
done

# === Publish the result ===
# A failed run raises SystemdUnitFailed; a run that never happens is caught by
# PostgreSQLRestoreTestStale, which reads this timestamp.
if [ -d "${TEXTFILE_DIR}" ]; then
    printf 'pg_restore_test_last_success_timestamp %s\n' "$(date +%s)" > "${METRIC_FILE}"
fi

echo "OK: ${DUMP} restored and verified"
