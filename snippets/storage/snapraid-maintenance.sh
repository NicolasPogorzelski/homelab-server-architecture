#!/usr/bin/env bash
set -euo pipefail

# Run snapraid sync or scrub and write a Prometheus textfile metric on success.
# Usage: snapraid-maintenance.sh sync|scrub
#
# Install on VM102:
#   install -m 0750 -o root -g root /dev/null /usr/local/sbin/snapraid-maintenance.sh
#   # copy script content, then add crontab entries as root:
#   echo "0 2 * * *   /usr/local/sbin/snapraid-maintenance.sh sync"    >> /etc/cron.d/snapraid
#   echo "0 3 1 * *   /usr/local/sbin/snapraid-maintenance.sh scrub"  >> /etc/cron.d/snapraid
#
# Prerequisite: node_exporter on VM102 must have the textfile collector enabled.
#   Add --collector.textfile.directory=/var/lib/node_exporter/textfile_collector
#   to ExecStart in /etc/systemd/system/node_exporter.service, then:
#   mkdir -p /var/lib/node_exporter/textfile_collector
#   systemctl daemon-reload && systemctl restart node_exporter

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
