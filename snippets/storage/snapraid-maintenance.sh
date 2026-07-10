#!/usr/bin/env bash
set -euo pipefail

# Run snapraid sync or scrub and write a Prometheus textfile metric on success.
# Usage: snapraid-maintenance.sh sync|scrub
#
# Deployed to VM102 by the `snapraid_maintenance` Ansible role, which also installs
# snapraid-sync.timer and snapraid-scrub.timer:
#   ansible-playbook playbooks/snapraid-maintenance.yml --check --diff
#
# Do not schedule this from cron. The host is powered down overnight, so a cron
# entry at 23:00 is silently skipped on every night the shutdown lands first and is
# never retried. The timers use Persistent=true and catch up at the next boot.
#
# Prerequisite: the textfile collector directory, created fleet-wide by the
# `node_exporter` role (node_exporter_textfile_dir).

MODE="${1:-}"
TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"

if [[ "$MODE" != "sync" && "$MODE" != "scrub" ]]; then
  echo "Usage: $0 sync|scrub" >&2
  exit 1
fi

if ! command -v snapraid &>/dev/null; then
  echo "ERROR: snapraid not found in PATH" >&2
  exit 1
fi

if [ ! -d "$TEXTFILE_DIR" ]; then
  echo "ERROR: textfile collector directory ${TEXTFILE_DIR} does not exist" >&2
  exit 1
fi

case "$MODE" in
  sync)
    snapraid sync
    echo "snapraid_sync_last_success_timestamp $(date +%s)" \
      > "${TEXTFILE_DIR}/snapraid_sync.prom"
    echo "OK: snapraid sync completed at $(date)"
    ;;
  scrub)
    snapraid scrub
    echo "snapraid_scrub_last_success_timestamp $(date +%s)" \
      > "${TEXTFILE_DIR}/snapraid_scrub.prom"
    echo "OK: snapraid scrub completed at $(date)"
    ;;
esac
