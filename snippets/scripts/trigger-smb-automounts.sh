#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

for d in /mnt/smb/*; do
  [[ -d "$d" ]] || continue
  timeout 3s ls -la "$d"/. >/dev/null 2>&1 || true
done
