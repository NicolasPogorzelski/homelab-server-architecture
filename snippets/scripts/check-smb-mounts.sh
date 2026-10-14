#!/usr/bin/env bash
# Boot-time verification of the /mnt/smb/* CIFS mounts on the Proxmox host.
#
# Runs after the guests are up (vm102 serves the shares), forces each automount
# to resolve, and fails if any /mnt/smb/* path is not backed by CIFS. The failed
# unit raises SystemdUnitFailed via node_exporter's systemd collector. See KE-15.
set -uo pipefail
shopt -s nullglob

failed=()

for d in /mnt/smb/*; do
  [[ -d "$d" ]] || continue

  # Force the automount to resolve. The access itself is the trigger.
  timeout 30s ls -1 "$d"/. >/dev/null 2>&1 || true

  # Check the mount's type, not its existence: a bind or an unmounted directory
  # reports ext4 (pve-root), the KE-15 signature.
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
