#!/usr/bin/env bash
#
# offsite-backup.sh - push this node's C1 datasets to the off-site restic
# repository and publish the result as node_exporter textfile metrics.
#
# Deployed by the Ansible role `offsite_backup`, driven by
# `offsite-backup.timer`. Configuration arrives through the environment file the
# role writes; nothing here is edited on the node.
#
# WHY THE CLIENT NEVER PRUNES. The REST server runs with --append-only, which
# means this credential can create snapshots and read them and cannot remove
# anything. That is the whole point of the target: a credential stolen from this
# side cannot destroy the copy it was stolen to reach. `restic forget` and
# `restic prune` therefore FAIL here by design, and retention is applied on the
# server, by a different account, out of reach of this node. A future reader
# looking for the missing retention step should read that sentence twice before
# adding one.
#
# WHY VERIFICATION IS SPLIT. `restic check` reads the repository's structure and
# is cheap; `--read-data-subset` re-downloads a fraction of the actual data and
# is not. The structural check runs every time, the data check on the day named
# by OFFSITE_VERIFY_WEEKDAY. Checking nothing is how a backup becomes a belief -
# the lesson pg-backup.sh already carries in its own header.
set -euo pipefail

: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY is not set}"
: "${RESTIC_PASSWORD_FILE:?RESTIC_PASSWORD_FILE is not set}"

BACKUP_PATHS="${OFFSITE_PATHS:?OFFSITE_PATHS is not set}"
TEXTFILE_DIR="${OFFSITE_TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
METRIC_FILE="${TEXTFILE_DIR}/offsite-backup.prom"
TAG="${OFFSITE_TAG:-$(hostname -s)}"
VERIFY_WEEKDAY="${OFFSITE_VERIFY_WEEKDAY:-7}"
VERIFY_SUBSET="${OFFSITE_VERIFY_SUBSET:-1%}"
EXCLUDE_FILE="${OFFSITE_EXCLUDE_FILE:-}"

START="$(date +%s)"
SUCCESS=0
SNAPSHOTS=0
VERIFIED=0

# Metrics are written whatever happens, including on the paths that exit early.
# A backup script that fails without leaving a metric behind is indistinguishable
# from one that was never scheduled, and the alert that would notice reads the
# metric rather than the journal.
publish() {
  local dur=$(( $(date +%s) - START ))
  local tmp
  tmp="$(mktemp "${METRIC_FILE}.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '${tmp}'" RETURN
  {
    echo "# HELP offsite_backup_success Whether the last off-site run completed (1) or not (0)."
    echo "# TYPE offsite_backup_success gauge"
    echo "offsite_backup_success ${SUCCESS}"
    echo "# HELP offsite_backup_last_run_timestamp_seconds Unix time of the last completed run."
    echo "# TYPE offsite_backup_last_run_timestamp_seconds gauge"
    echo "offsite_backup_last_run_timestamp_seconds ${START}"
    echo "# HELP offsite_backup_duration_seconds Wall-clock duration of the last run."
    echo "# TYPE offsite_backup_duration_seconds gauge"
    echo "offsite_backup_duration_seconds ${dur}"
    echo "# HELP offsite_backup_snapshots Snapshots this node's tag holds in the repository."
    echo "# TYPE offsite_backup_snapshots gauge"
    echo "offsite_backup_snapshots ${SNAPSHOTS}"
    echo "# HELP offsite_backup_last_verify_timestamp_seconds Unix time of the last data verification."
    echo "# TYPE offsite_backup_last_verify_timestamp_seconds gauge"
    echo "offsite_backup_last_verify_timestamp_seconds ${VERIFIED}"
  } > "${tmp}"
  # node_exporter runs under its own account and skips a file it cannot read
  # without logging anything, so the metric would simply be absent - which reads
  # exactly like a fleet with no backups configured.
  chmod 0644 "${tmp}"
  mv -f "${tmp}" "${METRIC_FILE}"
}
trap publish EXIT

mkdir -p "${TEXTFILE_DIR}"

# Read back the previous verification timestamp so a run that does not verify
# does not reset the clock the staleness rule reads.
if [ -f "${METRIC_FILE}" ]; then
  VERIFIED="$(awk '/^offsite_backup_last_verify_timestamp_seconds /{print $2}' "${METRIC_FILE}" 2>/dev/null || echo 0)"
  [ -z "${VERIFIED}" ] && VERIFIED=0
fi

# Every path must exist. A missing source is silently skipped by `restic backup`,
# which produces a smaller snapshot and a successful exit - the failure mode where
# a backup keeps succeeding while covering less and less.
for p in ${BACKUP_PATHS}; do
  if [ ! -e "${p}" ]; then
    echo "ERROR: source path does not exist: ${p}" >&2
    exit 1
  fi
done

# The repository must answer before anything else is attempted, so an unreachable
# target fails in one second with a clear message rather than after an hour of
# reading local data.
if ! restic cat config >/dev/null 2>&1; then
  echo "ERROR: repository ${RESTIC_REPOSITORY} is unreachable or the password is wrong" >&2
  exit 1
fi

BACKUP_ARGS=(backup --tag "${TAG}" --host "${TAG}")
[ -n "${EXCLUDE_FILE}" ] && [ -f "${EXCLUDE_FILE}" ] && BACKUP_ARGS+=(--exclude-file "${EXCLUDE_FILE}")

# shellcheck disable=SC2086
restic "${BACKUP_ARGS[@]}" ${BACKUP_PATHS}

# Structural check on every run: does the repository still describe itself
# consistently. This is what catches a truncated upload before the next restore
# does.
restic check --no-lock

if [ "$(date +%u)" = "${VERIFY_WEEKDAY}" ]; then
  restic check --no-lock --read-data-subset "${VERIFY_SUBSET}"
  VERIFIED="$(date +%s)"
fi

SNAPSHOTS="$(restic snapshots --tag "${TAG}" --json | grep -c '"short_id"' || true)"
SUCCESS=1
echo "off-site backup complete: ${SNAPSHOTS} snapshots under tag ${TAG}"
