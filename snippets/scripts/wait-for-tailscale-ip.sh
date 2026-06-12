#!/bin/bash
# Block until this node's Tailscale IPv4 address is assigned to a local
# interface, so a service that binds the Tailscale IP directly (PostgreSQL
# listen_addresses on LXC260) does not start before the address exists at boot.
# Used as ExecStartPre= for postgresql@15-main.service (KE-9 remediation).
#
# Fail-open: on timeout it logs a warning and exits 0, so PostgreSQL still
# starts (loopback-only) rather than failing the unit entirely.

set -euo pipefail

TIMEOUT="${1:-90}"   # max seconds to wait for the Tailscale IP before giving up
INTERVAL=2           # seconds between polls
elapsed=0

while [ "$elapsed" -lt "$TIMEOUT" ]; do
  # tailscale ip -4 prints this node's own Tailscale IPv4 once tailscaled is up.
  if ts_ip="$(tailscale ip -4 2>/dev/null)" && [ -n "$ts_ip" ]; then
    # Confirm the address is actually on a local interface, not merely known to
    # tailscaled: bind() needs it present or it fails with EADDRNOTAVAIL.
    if ip -4 -o addr show | grep -qFw "$ts_ip"; then
      echo "wait-for-tailscale-ip: ${ts_ip} present after ${elapsed}s"
      exit 0
    fi
  fi
  sleep "$INTERVAL"
  elapsed=$((elapsed + INTERVAL))
done

echo "wait-for-tailscale-ip: WARNING tailscale IP not present after ${TIMEOUT}s; starting anyway" >&2
exit 0
