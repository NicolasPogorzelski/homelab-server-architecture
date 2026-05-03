# Runbook: SMB autofs boot stabilization

## Problem
SMB mounts under `/mnt/smb/*` are access-triggered (autofs/systemd automount). Some services may access bind-mounted paths during startup before the automount is activated, causing:
- empty directories instead of mounted storage
- failed migrations / startup errors
- nondeterministic reboot behavior

## Preconditions

- VM102 (Storage) is running and Samba is active
- SMB automount units exist under `/mnt/smb/*` on the Proxmox host
- Network is reachable (automounts depend on `network-online.target`)

## Solution (Proxmox host)
Create a systemd oneshot unit that triggers all `/mnt/smb/*` automounts after `network-online.target`, forcing early activation during boot.

## Implementation (script-based, recommended)

Repo snippets (source of truth for this runbook):

- Unit: [trigger-smb.mounts.service](../../snippets/systemd/trigger-smb.mounts.service)
- Script: [trigger-smb-automounts.sh](../../snippets/scripts/trigger-smb-automounts.sh)

Rationale:
- Avoid complex quoting in ExecStart (common systemd failure mode)
- Keep logic testable as a standalone script
- The unit stays stable while the script can evolve

---

### Install steps (Proxmox host)

1) Install script

install -m 0755 -o root -g root /dev/null /usr/local/sbin/trigger-smb-automounts.sh
nano /usr/local/sbin/trigger-smb-automounts.sh

Script content:

#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

for d in /mnt/smb/*; do
  [[ -d "$d" ]] || continue
  timeout 3s ls -la "$d"/. >/dev/null 2>&1 || true
done

2) Install unit

nano /etc/systemd/system/trigger-smb.mounts.service

Unit content:

[Unit]
Description=Trigger all SMB automounts (boot stabilization)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/trigger-smb-automounts.sh

[Install]
WantedBy=multi-user.target

3) Enable + start

systemctl daemon-reload
systemctl enable --now trigger-smb.mounts.service

---

## Verification

systemctl status trigger-smb.mounts.service --no-pager
findmnt -t cifs | grep -E '^/mnt/smb/' || true
/usr/local/sbin/trigger-smb-automounts.sh

---

## Failure Modes

| Symptom | Likely Cause | Action |
|---|---|---|
| Unit stays `failed` after boot | Script not executable or path wrong | Check `ls -l /usr/local/sbin/trigger-smb-automounts.sh`; verify `ExecStart` path matches |
| `/mnt/smb/*` dirs still empty after trigger | VM102 or Samba not yet ready at trigger time | Check `systemctl status smb` on VM102; verify `network-online.target` dependency is active |
| `findmnt` shows no CIFS mounts | Automount units not configured or wrong mount paths | Inspect `/etc/systemd/system/mnt-smb-*.mount` units; verify `pct config` mp entries |
| Script exits immediately, no mounts triggered | No directories found under `/mnt/smb/` | Confirm `shopt -s nullglob` is set; check that automount dirs exist on Proxmox host |

---

## Notes
- Databases must not run on CIFS/SMB.
- This boot trigger reduces race conditions for automount-backed shares.
