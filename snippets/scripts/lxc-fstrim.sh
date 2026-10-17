#!/usr/bin/env bash
# Return blocks freed inside LXC containers to the LVM thin pool on the Proxmox host.
#
# Trimming containers is the host's job: the stock fstrim.timer carries
# ConditionVirtualization=!container, and an unprivileged container is refused the FITRIM
# ioctl anyway, while both report healthy.
#
# pve/data is a thin pool: it allocates chunks on first write and frees them only on
# discard, so without trimming it fills while the filesystems look half empty (KE-7).
# Discard passdown to the boot SSD is unsupported behind the SAS HBA; the pool still frees
# its own chunks, which is what matters here.
#
# The container list comes from `pct list`, so a new container is covered on creation.
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

# The before/after lines in `journalctl -u lxc-fstrim` show how much each run reclaims;
# the fill level itself is exported by lvm-thin-metrics.sh.

if (( ${#failed[@]} > 0 )); then
  printf "fstrim FAILED for %d container(s): %s\n" "${#failed[@]}" "${failed[*]}" >&2
  exit 1
fi

printf "fstrim OK: all %d running containers trimmed\n" "${#ctids[@]}"
