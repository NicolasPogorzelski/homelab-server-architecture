# Runbook: Boot SSD replacement

- **Use when:** replacing the boot SSD ([KE-14](../../docs/platform/known-errors.md#ke-14));
  planned for the second half of October 2026
  ([remediation plan](../../docs/platform/remediation-plan.md#boot-ssd-replacement)).
- **Duration:** half a day with physical presence; most of it is restore time.
- **Risk:** the restore depends on archives on the aux-disk
  ([KE-13](../../docs/platform/known-errors.md#ke-13)); writes made on the new disk are lost if the
  old disk is put back.
- **Last exercised:** never

The boot SSD carries Proxmox, the `pve/data` thin pool and every guest root disk, in a 110 GiB
volume group. It is replaced by a fresh Proxmox installation on a larger disk and a rebuild with
[`platform-restore.md`](platform-restore.md), not by a clone: a clone keeps the old partition
sizes, the rebuild is the platform's full restore test, and the old SSD stays untouched as the
rollback.

## Preconditions

- Port decided and recorded. Same HBA port and cable separates the media from the transport; an
  onboard SATA port separates the HBA path from power and gives the SSD the TRIM the HBA blocks.
- Backups current, the day before:
  - `systemctl start guest-backup.service`; every guest in `plan`, vm100 included.
  - `systemctl start host-config-backup.service` after the last configuration change.
  - `PostgreSQLBackupStale` and `MariaDBBackupStale` quiet.
- On the old host: `platform-restore.sh plan` reports no gap and
  `platform-restore.sh test-restore 260` passes. Outputs recorded.
- A second copy of the newest archive per guest and the newest host configuration archive, off the
  aux-disk (admin workstation or vm102's pool). The host configuration archive holds the CIFS
  credentials, `/etc/shadow` and the Tailscale node key: encrypted disk or `age -r <recipient>`
  first, never plain files on a workstation.
- KE-14 baseline: failed commands per boot since 2026-10-13 (7.0 kernel), per boot `<n>`:
  `journalctl -k -b <n> | grep -cE '9:0:0:0.*(DID_SOFT_ERROR|DID_TIME_OUT)'`.
- Proxmox VE installer on USB, same major version as `pveversion`.
- Physical presence: the host has no console once Linux runs.

## Steps

1. Shut down the host; remove the old SSD, label and store it; fit the new SSD at the decided port.
   Check: the firmware lists the new disk.
2. Install Proxmox VE on the new SSD: hostname `server`, the same address on `vmbr0`, the root
   password held in the escrow.
   Check: `pveversion` matches the major version in the archive; `ssh root@<lan-ip-proxmox>`
   from an admin workstation works.
3. Rebuild with [`platform-restore.md`](platform-restore.md), steps 2 to 6.
   Check: that runbook's checks pass; `platform-restore.sh verify` lists all nine guests running.
4. From lxc250: the playbooks for the `proxmox` group, `fleet-health-check.yml`, a drift sweep.
   Check: no failed hosts, no drift.
5. Update the documents the swap changes: the disk identity in
   [`proxmox-host.md`](../../docs/platform/proxmox-host.md), KE-14 with the port and the first
   counts, the `by-id` placeholders wherever the old disk is named.
   Check: `grep -rn '<old-disk-id>' docs/ runbooks/` prints nothing.

## Verification

- The verification of [`platform-restore.md`](platform-restore.md#verification).
- `lvs pve/data` shows the larger pool; `LvmThinPoolWarning` quiet.
- KE-14: failed commands per boot over the first week, against the baseline.
- `GuestBackupStale` and `HostConfigBackupStale` quiet after the first Saturday.

## Failure modes

| Symptom | Action |
|---|---|
| Installer does not see the new SSD on the HBA | Onboard SATA port, or the old SSD back and the swap postponed |
| A restore step fails | The table in [`platform-restore.md`](platform-restore.md#failure-modes); the old SSD is the fallback at any point |
| KE-14 errors continue on the new SSD | Transport path: [`ke14-power-path-check.md`](ke14-power-path-check.md) |

## Rollback

Power off, put the old SSD back on its original port, boot. Nothing on it changed. Writes made on
the new disk since the swap are lost: database rows, Nextcloud uploads and Paperless imports of
those hours. Files those services wrote to vm102's pool survive without the database rows that
index them.

## Background

The swap is also the KE-14 test: failed commands per boot before and after. The 6.17.13 kernel pin
was released on 2026-10-12, so the kernel and the drive do not change together. Related:
[guest-backup-restore.md](guest-backup-restore.md).
