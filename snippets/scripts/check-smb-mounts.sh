#!/usr/bin/env bash
# Boot-time verification of the /mnt/smb/* CIFS mounts on the Proxmox host.
#
# Replaces trigger-smb-automounts.sh, which could not work by construction: it ran
# After=network-online.target, i.e. BEFORE pve-guests started VM102, so it poked automounts
# whose SMB server did not exist yet -- and it swallowed every error (`|| true`), so it
# reported success unconditionally.
#
# This script does the opposite: it runs after the guests are up, forces each automount to
# resolve, and FAILS LOUDLY if any /mnt/smb/* path is not backed by CIFS. A failing unit is
# exported by node_exporter --collector.systemd and raises SystemdUnitFailed in Prometheus.
# KE-15 stayed invisible for a month precisely because nothing failed loudly.
set -uo pipefail
shopt -s nullglob

failed=()

for d in /mnt/smb/*; do
  [[ -d "$d" ]] || continue

  # Force the automount to resolve. The access itself is the trigger.
  timeout 30s ls -1 "$d"/. >/dev/null 2>&1 || true

  # What matters is not that *a* mount exists, but that the *right kind* does.
  # A bind or an unmounted directory reports ext4 (pve-root) -- the KE-15 signature.
  fstype="$(findmnt -no FSTYPE --target "$d" 2>/dev/null | tail -1)"
  if [[ "$fstype" != "cifs" ]]; then
    failed+=("$d (fstype=${fstype:-none}, expected cifs)")
  fi
done

if (( ${#failed[@]} > 0 )); then
  printf "SMB mount check FAILED for %d path(s):\n" "${#failed[@]}" >&2
  printf "  %s\n" "${failed[@]}" >&2
  exit 1
fi

printf "SMB mount check OK: all /mnt/smb/* paths are cifs\n"
