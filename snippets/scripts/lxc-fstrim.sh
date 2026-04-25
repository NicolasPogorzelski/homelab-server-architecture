#!/bin/bash
# Run fstrim on all running LXC containers via nsenter.
# Execute on the Proxmox host after ansible apt-upgrade playbook.

set -euo pipefail

CTIDS=(200 210 211 220 230 240 260)

for ctid in "${CTIDS[@]}"; do
  PID=$(lxc-info -n "$ctid" 2>/dev/null | awk '/^PID:/{print $2}')
  if [ -z "$PID" ]; then
    echo "lxc${ctid}: not running, skipping"
    continue
  fi
  echo "lxc${ctid} (PID ${PID}): trimming..."
  nsenter -t "$PID" --mount -- fstrim -v /
done
