#!/usr/bin/env bash
# Return blocks freed inside LXC containers to the LVM thin pool on the Proxmox host.
#
# Why this cannot run inside the containers: the stock fstrim.timer carries
# ConditionVirtualization=!container, so systemd skips it there, and an unprivileged
# container is refused the ioctl anyway ("FITRIM ioctl failed: Operation not permitted").
# Both guards report healthy -- `systemctl is-enabled` says "enabled" and Result=success is
# the default of a unit that never ran -- so nothing ever failed and nothing ever ran.
# Trimming containers is the host's job, structurally, not a misconfiguration.
#
# Why this matters here: pve/data is a thin pool. It hands out 64 KiB chunks on first write
# and never takes them back on delete, because a filesystem's notion of "free" does not
# reach the block layer on its own. Measured 2026-08-10: 92.55% allocated against 23 GiB
# actually in use, with VFree=0 on the VG -- so lvextend is not available as an escape.
# That is the KE-7 failure class (thin-pool overflow corrupting packages mid-apt).
#
# Discard passdown to the physical disk is disabled by the kernel on this host
# ("device-mapper: thin: Data device (dm-3) discard unsupported"), because the boot SSD sits
# behind an LSI SAS2008 that does not translate UNMAP to TRIM for SATA drives. That only
# costs the SSD-side benefit; the pool still frees its own chunks, which is what we need.
#
# Predecessor: this replaces a hardcoded CTID array that omitted lxc250 -- the fullest
# container in the fleet, and the same node that is absent from the Ansible inventory. The
# list is now derived from the running fleet so a new container is covered on creation.
set -uo pipefail

POOL="pve/data"

pool_percent() {
  lvs --noheadings -o data_percent "${POOL}" 2>/dev/null | tr -d ' '
}

mapfile -t ctids < <(pct list 2>/dev/null | awk 'NR > 1 && $2 == "running" { print $1 }')

if (( ${#ctids[@]} == 0 )); then
  printf "No running containers found -- nothing to trim, and that is suspicious.\n" >&2
  exit 1
fi

before="$(pool_percent)"
printf "%s before trim: %s%% allocated (%d running containers)\n" \
  "${POOL}" "${before:-unknown}" "${#ctids[@]}"

# No `set -e`: one container that refuses to trim must not skip every container after it.
# Failures are collected and reported together, and the exit status is non-zero at the end.
failed=()

for ctid in "${ctids[@]}"; do
  if output="$(pct fstrim "${ctid}" 2>&1)"; then
    printf "  ct%s: %s\n" "${ctid}" "${output:-trimmed}"
  else
    printf "  ct%s: FAILED -- %s\n" "${ctid}" "${output}" >&2
    failed+=("${ctid}")
  fi
done

after="$(pool_percent)"
printf "%s after trim:  %s%% allocated (was %s%%)\n" \
  "${POOL}" "${after:-unknown}" "${before:-unknown}"

# Until a thin-pool metric reaches Prometheus, this log is the only record of how fast the
# pool refills. `journalctl -u lxc-fstrim` gives the growth rate between runs.

if (( ${#failed[@]} > 0 )); then
  printf "fstrim FAILED for %d container(s): %s\n" "${#failed[@]}" "${failed[*]}" >&2
  exit 1
fi

printf "fstrim OK: all %d running containers trimmed\n" "${#ctids[@]}"
