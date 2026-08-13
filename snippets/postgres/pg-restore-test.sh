#!/usr/bin/env bash
#
# Validate that the newest pg_dumpall backup can actually be restored.
#
# This is the *validation* counterpart to runbooks/database/pg-restore.md. That
# runbook holds the recovery procedure, which drops a live database and can
# therefore only be rehearsed by accepting an outage. Here nothing live is
# touched: the dump is restored into a throwaway cluster on a second port, the
# result is asserted, and the cluster is destroyed again.
#
# Deliberately does NOT compare against the live database. Append-only tables
# (task queues, audit logs) keep growing after the dump was taken, so a live
# comparison reports a difference on every single run and the alert gets muted.
# The dump is checked against itself instead: complete, restorable, and yielding
# databases that hold data.
#
# Deployed by the postgresql_restore_test role. Edit this file, never the copy
# on the node.

set -euo pipefail

# === Configuration ===
BACKUP_DIR="/mnt/backups"
PG_VERSION="15"
TEST_CLUSTER="restoretest"
TEST_PORT="5433"

# Must match the live cluster (SELECT datcollate FROM pg_database). The dump
# carries CREATE DATABASE ... LC_COLLATE 'en_US.UTF-8', which fails against a
# cluster built with a different locale — and the container's own default is
# LANG=C, so this cannot be left implicit.
TEST_LOCALE="en_US.UTF-8"

TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
METRIC_FILE="${TEXTFILE_DIR}/pg_restore_test.prom"

# Ignore dumps younger than this. pg-backup.service may be writing one right now
# — most likely during a boot-window catch-up, when both timers fire — and a
# half-written file would fail the integrity check and report a false alarm.
# Same "wait until it has settled" guard as calibre-import.sh uses on inbox files.
DUMP_MIN_AGE_MIN=5

# "database:table" pairs that must exist and hold at least one row afterwards.
# A dump truncated after the schema but before the COPY blocks restores without
# any error at all and yields empty tables. The completion-marker check below is
# the primary defence against that; this is the second.
EXPECTED_TABLES=(
    "paperless_db:documents_document"
    "openwebui_db:migratehistory"
)

# psql errors that are expected. pg_dumpall emits CREATE ROLE for every role in
# the source cluster, and the throwaway cluster already has its own postgres
# superuser from initdb.
ERROR_ALLOWLIST='^ERROR:  role ".*" already exists$'

STDERR_LOG=""

# === Helpers ===

cluster_exists() {
    pg_lsclusters -h 2>/dev/null \
        | awk -v v="${PG_VERSION}" -v c="${TEST_CLUSTER}" \
              '$1 == v && $2 == c { found = 1 } END { exit !found }'
}

# Runs on every exit path, including failures and signals, so an aborted run
# cannot leave a cluster occupying the port. Each step is guarded: a failure
# inside the trap must not replace the script's real exit status.
cleanup() {
    if cluster_exists; then
        pg_dropcluster "${PG_VERSION}" "${TEST_CLUSTER}" --stop \
            || echo "WARNING: could not drop cluster ${TEST_CLUSTER} — remove it by hand" >&2
    fi
    [ -n "${STDERR_LOG}" ] && rm -f "${STDERR_LOG}"
    return 0
}
trap cleanup EXIT

# === Pre-flight: is the backup share actually mounted? ===
# Test the mount's identity, not that the path exists. /mnt/backups is a bind of
# the host's CIFS mount of //vm102/Postgres-Backups; if that mount is down, the
# directory still exists and is empty, and this script would report "no dumps
# found" when the truth is "the share is unreachable". That is the KE-15 class.
FSTYPE="$(findmnt -no FSTYPE "${BACKUP_DIR}" 2>/dev/null || true)"
if [ "${FSTYPE}" != "cifs" ]; then
    echo "ERROR: ${BACKUP_DIR} is not a CIFS mount (fstype='${FSTYPE:-none}')" >&2
    exit 1
fi

# === Select the newest settled dump ===
# awk, not `head -1`: head exits after the first line and closes the pipe, which
# can hand `sort` a SIGPIPE — and `set -o pipefail` would turn that into a failed
# run. It survives here only because five filenames fit in the pipe buffer, which
# is luck, not design. awk reads its input to the end and cannot trigger it.
# The sub() strips the sort key rather than using $2, so a path containing a
# space would still survive.
DUMP="$(find "${BACKUP_DIR}" -maxdepth 1 -type f -name 'pg_dumpall_*.sql.gz' \
        -mmin "+${DUMP_MIN_AGE_MIN}" -printf '%T@ %p\n' \
        | sort -rn | awk 'NR == 1 { sub(/^[^ ]+ /, ""); print }')"
if [ -z "${DUMP}" ]; then
    echo "ERROR: no dump older than ${DUMP_MIN_AGE_MIN} min in ${BACKUP_DIR}" >&2
    exit 1
fi
echo "selected dump: ${DUMP}"

# === Integrity: can the dump be read back at all? ===
# Two checks, and the second is the one that matters. gzip -t proves the
# compressed stream is intact; it does not prove the dump is complete, because a
# pg_dumpall killed mid-write still produces a valid gzip member. Only the
# trailer that pg_dumpall writes as its final line separates finished from
# truncated — and the backup script checks neither.
if ! gzip -t "${DUMP}"; then
    echo "ERROR: ${DUMP} fails the gzip integrity check" >&2
    exit 1
fi

MARKERS="$(gzip -cd "${DUMP}" | grep -c 'PostgreSQL database cluster dump complete' || true)"
if [ "${MARKERS}" -ne 1 ]; then
    echo "ERROR: ${DUMP} carries ${MARKERS} completion markers, expected 1 — truncated dump" >&2
    exit 1
fi

# === Remove a cluster left behind by an aborted earlier run ===
# Without this, a single interrupted run makes every later run fail on the
# occupied port. A test that stays red after one mishap gets switched off rather
# than repaired.
if cluster_exists; then
    echo "removing a stale ${TEST_CLUSTER} cluster from a previous run"
    pg_dropcluster "${PG_VERSION}" "${TEST_CLUSTER}" --stop
fi

# === Throwaway cluster ===
# --start-conf manual: should this script be killed between here and cleanup,
# the leftover cluster must not be started again at the next boot.
pg_createcluster "${PG_VERSION}" "${TEST_CLUSTER}" \
    --port "${TEST_PORT}" --locale "${TEST_LOCALE}" --start-conf manual
pg_ctlcluster "${PG_VERSION}" "${TEST_CLUSTER}" start

# === Restore ===
# Every psql call carries --port. That flag is the only thing separating this
# script from overwriting production, which is why it is never defaulted.
# runuser drops to postgres: a fresh cluster authenticates local superuser
# connections by peer, so root cannot connect as postgres.
STDERR_LOG="$(mktemp)"
if ! gzip -cd "${DUMP}" \
        | runuser -u postgres -- psql --port "${TEST_PORT}" --quiet --dbname postgres \
          >/dev/null 2>"${STDERR_LOG}"; then
    echo "ERROR: restore failed — psql exited non-zero" >&2
    head -20 "${STDERR_LOG}" >&2
    exit 1
fi

# psql returns 0 even when individual statements fail (there is no
# ON_ERROR_STOP here, because the expected role collision would then abort the
# whole restore). The exit code above is therefore necessary but not sufficient:
# classify what it wrote to stderr.
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
# A run that fails raises SystemdUnitFailed. A run that never happens raises
# nothing at all — the gap LvmThinMetricsStale exists for — so publish a
# timestamp and let PostgreSQLRestoreTestStale alert on its age.
if [ -d "${TEXTFILE_DIR}" ]; then
    printf 'pg_restore_test_last_success_timestamp %s\n' "$(date +%s)" > "${METRIC_FILE}"
fi

echo "OK: ${DUMP} restored and verified"
