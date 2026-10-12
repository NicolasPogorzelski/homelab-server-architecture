# Runbook: Boot SSD replacement

## Problem

The boot SSD carries Proxmox, the `pve/data` thin pool and every guest root disk. At 110 GiB of
volume group it is too small for what it carries, and it is the disk behind
[KE-14](../../docs/platform/known-errors.md#ke-14). It is replaced in the second half of October
2026, decided on 2026-10-12.

## Solution

Install Proxmox fresh on the new SSD and rebuild the platform from its backups with
[`platform-restore.md`](platform-restore.md), instead of cloning the old disk. Three reasons:

- A clone carries the old disk's partition sizes, and the point of the swap is a larger pool.
- The rebuild is the full restore test this platform cannot otherwise run without a second machine.
  Every gap it finds is found with the old disk still on the shelf.
- The old SSD stays untouched, so the rollback is putting it back.

The swap is also the KE-14 test: the failed-command count per boot before and after. Same HBA port
and cable separates the media from the transport; an onboard SATA port separates the HBA path from
the power, and gives the SSD the TRIM the HBA blocks (remediation item 7). Decide which before the
day, and record it.

## Precondition

- **Backups current, the day before:**
  - `guest-backup.service` run by hand (`systemctl start guest-backup.service`), every guest in
    `plan`, vm100 included;
  - `host-config-backup.service` run by hand after the last configuration change;
  - fresh PostgreSQL and MariaDB dumps (`PostgreSQLBackupStale` and `MariaDBBackupStale` quiet).
- **Proven on the old host:** `platform-restore.sh plan` reports no gap and
  `platform-restore.sh test-restore 260` passes. Record both outputs.
- **A second copy of the archive set.** Every guest archive sits on the auxiliary disk, the KE-13
  disk. Copy the newest archive per guest and the newest host configuration archive to the admin
  notebook, or onto vm102's pool, before the old SSD comes out. The host configuration archive
  holds the CIFS credentials, `/etc/shadow` and the Tailscale node key: it goes onto an encrypted
  disk or is encrypted first (`age -r <recipient>`), never as plain files onto a workstation.
- **KE-14 baseline:** the per-boot count from the boots since 2026-10-13, all on the 7.0 kernel:
  `journalctl -k -b <n> | grep -cE '9:0:0:0.*(DID_SOFT_ERROR|DID_TIME_OUT)'`.
- Proxmox VE installer on a USB stick, same major version as `pveversion`.
- Physical presence: the host has no remote console once Linux runs.

## Procedure

1. Shut down the host. Remove the old SSD, label it, store it. Fit the new one at the decided port.
2. Install Proxmox VE: target the new SSD, hostname `server`, the same address on `vmbr0`, the same
   root password the escrow holds.
3. Follow [`platform-restore.md`](platform-restore.md) from "On the new installation".
4. From lxc250: the playbooks for the `proxmox` group, then `fleet-health-check.yml` and a drift
   sweep.
5. Update the documents the swap changes: the disk identity in
   [`proxmox-host.md`](../../docs/platform/proxmox-host.md), the KE-14 entry with the port used and
   the first counts, and the `by-id` placeholders wherever the old disk was named.

## Verification

- Everything in the verification of [`platform-restore.md`](platform-restore.md).
- `lvs pve/data` shows the larger pool; `LvmThinPoolWarning` quiet.
- KE-14: the per-boot count over the first week, against the baseline.
- The guest backup and the host configuration backup both run on schedule on the new disk
  (`GuestBackupStale`, `HostConfigBackupStale` quiet after the first Saturday).

## Failure

| Symptom | Action |
|---|---|
| The installer does not see the new SSD on the HBA | Onboard SATA port, or the old SSD back and the swap postponed |
| A step of the restore fails | The table in [`platform-restore.md`](platform-restore.md#failure); the old SSD is the fallback at any point |
| KE-14 errors continue on the new SSD | The transport path: run [`ke14-power-path-check.md`](ke14-power-path-check.md) |

## Rollback

Power off, put the old SSD back on its original port, boot. Nothing on it changed. Guests that ran
on the new disk lose what they wrote since the swap: database writes, Nextcloud uploads and
Paperless imports of those hours, all of which also reached vm102's pool only as files and not as
the database rows that index them.

## Related

- [Platform restore](platform-restore.md)
- [Guest backup and restore](guest-backup-restore.md)
- [KE-14 power-path check](ke14-power-path-check.md)
