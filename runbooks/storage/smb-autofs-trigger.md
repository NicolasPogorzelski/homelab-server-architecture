# Runbook: SMB autofs boot stabilization

## Problem
SMB mounts under `/mnt/smb/*` are access-triggered (autofs/systemd automount). Some services may access bind-mounted paths during startup before the automount is activated, causing:
- empty directories instead of mounted storage
- failed migrations / startup errors
- nondeterministic reboot behavior

## Solution (Proxmox host)
Create a systemd oneshot unit that touches all `/mnt/smb/*` directories after `network-online.target`, forcing automount activation early in boot.

### Unit file
Path: `/etc/systemd/system/trigger-smb.mounts.service`

Core behavior:
- After/Wants: `network-online.target`
- ExecStart: list each directory under `/mnt/smb` once (touch/ls)

## Verification
- `systemctl status trigger-smb.mounts.service`
- `findmnt | grep -E "/mnt/smb|cifs"`

## Notes
- Databases must not run on CIFS/SMB (even if it seems stable).
- This boot trigger reduces a whole class of race conditions for automount-backed shares.
