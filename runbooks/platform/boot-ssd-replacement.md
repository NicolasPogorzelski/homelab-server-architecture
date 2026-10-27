# Runbook: Boot disk replacement

- **Use when:** the disk carrying Proxmox, `/boot/efi` and the `pve/data` thin pool is replaced by
  a new disk fitted beside it ([KE-14](../../docs/platform/known-errors.md#ke-14)).
- **Duration:** about an hour; the guests are down for 15 to 20 minutes.
- **Risk:** after `vgreduce` the old disk is no longer a bootable copy; the way back is
  `vgcfgrestore` from `/etc/lvm/archive` or the guest backups. Everything on the new disk is
  erased in step 2.
- **Last exercised:** 2026-10-27, pass (Samsung 840 EVO 120 GB on the SAS HBA to a SanDisk A400
  512 GB NVMe in the M.2 slot; guests down 13:08 to 13:25)

The volume group `pve` moves online with `pvmove`; Proxmox is not reinstalled and no guest is
restored. The thin pool's data and metadata are plain linear sub-LVs, which `pvmove` moves like
`root` and `swap`. The full restore test this would otherwise include is a separate item in the
[remediation plan](../../docs/platform/remediation-plan.md).

## Preconditions

- New disk fitted and listed: `lsblk -d -o NAME,MODEL,SIZE,TRAN`, `ls /dev/disk/by-id/`. Address
  it only by `by-id` below; its old content is erased.
- Backups current, the same day:
  - `systemctl start guest-backup.service`; `Result=success`, nine archives.
  - A second copy of those archives and the newest host configuration archive off the aux-disk, on
    an encrypted disk, checked with `sha256sum -c`.
- Bootloader known: `findmnt /boot/efi`, `efibootmgr`, `proxmox-boot-tool status`. This host boots
  GRUB with shim from the ESP in `/etc/fstab`; `proxmox-boot-tool` is not in use.
- No guest snapshot that is no longer needed (`qm listsnapshot <vmid>`); a snapshot of a VM with
  disks on two storages has a half in the thin pool.

## Steps

1. Layout of the old disk: `sgdisk -p <old-disk>`.
   Check: BIOS boot, ESP and LVM partitions, in that order.
2. Partition the new disk with the same roles, aligned:
   ```bash
   N=/dev/disk/by-id/<new-disk-by-id>
   sgdisk -Z $N
   sgdisk -n1:2048:+1M -t1:EF02 -n2:0:+1G -t2:EF00 -n3:0:0 -t3:8E00 $N
   blockdev --rereadpt $N; udevadm settle
   mkfs.vfat -F 32 ${N}-part2
   ```
   Check: `sgdisk -p $N` shows three partitions; `wipefs ${N}-part3` prints nothing.
3. Copy the ESP: mount `${N}-part2` on `/mnt/newesp`, `cp -a /boot/efi/. /mnt/newesp/`, unmount.
   Check: `diff -r /boot/efi /mnt/newesp` prints nothing. The GRUB stub finds root by filesystem
   UUID and `lvmid`, which `pvmove` does not change.
4. Add the new disk and test the move:
   ```bash
   pvcreate ${N}-part3
   vgextend pve ${N}-part3
   pvmove --test <old-disk>-part3 ${N}-part3
   ```
   Check: no error. Up to here `vgreduce pve ${N}-part3` undoes everything.
5. Stop every guest (`pvesh create /nodes/server/stopall`), then `pvmove -i 60 <old-disk>-part3
   ${N}-part3`.
   Check: `pvs` shows the old PV with all extents free; `lvs -a -o lv_name,devices pve` names only
   the new disk.
6. Take the old disk out and move the boot path:
   ```bash
   vgreduce pve <old-disk>-part3
   cp -a /etc/fstab /etc/fstab.pre-<date>
   # /etc/fstab: the /boot/efi line gets the UUID of ${N}-part2 (blkid)
   umount /boot/efi; systemctl daemon-reload; mount /boot/efi
   efibootmgr -c -d <new-disk-kernel-name> -p 2 -L proxmox-<name> -l '\EFI\proxmox\shimx64.efi'
   ```
   Check: `findmnt /boot/efi` names the new ESP; the new entry is first in `BootOrder`, the old
   `proxmox` entry stays behind it as a fallback. Delete entries whose partition no longer exists
   (`efibootmgr -b <n> -B`).
7. Grow the pool, keep a reserve in the volume group:
   ```bash
   lvextend -L +<size>G pve/data
   lvextend --poolmetadatasize <size>G pve/data
   ```
   Check: `lvs -a pve` shows `data`, `data_tmeta` and `lvol0_pmspare` at the new sizes; `vgs pve`
   keeps the planned free space. A thin pool cannot shrink.
8. `update-grub`, then reboot.
   Check: `efibootmgr` reports `BootCurrent` as the new entry; `findmnt /` is `pve-root`; all nine
   guests run; `systemctl --failed` is empty.
9. From lxc250: `fleet-health-check.yml` and a drift sweep.
   Check: no failed hosts, `changed 0`.
10. Update the documents the swap changes: the disk in
    [`proxmox-host.md`](../../docs/platform/proxmox-host.md), KE-14, the failure domains and the
    remediation plan.

## Verification

- `lvs pve/data` shows the larger pool; `LvmThinPoolWarning` quiet.
- KE-14: failed commands per boot over the following week, at `9:0:0:0` (now the idle old disk)
  and on every other HBA port.
- `GuestBackupStale` and `HostConfigBackupStale` quiet after the first Saturday.

## Failure modes

| Symptom | Action |
|---|---|
| `sgdisk` refuses partition 1 at sector 34 | The new disk aligns to 2048; start partition 1 there |
| `partprobe: command not found` | `blockdev --rereadpt`, then `udevadm settle` |
| `pvmove` stops part-way | `pvmove` without arguments resumes it; `pvmove --abort` returns to the old disk |
| The host boots the old ESP | `efibootmgr -o` with the new entry first; both ESPs boot the same root |
| ServiceDown on vm100 for minutes after boot | Docker waits for the Tailscale address (`tailscale_boot_gate`); wait for it |

## Rollback

Before step 6: `pvmove` back, or `vgreduce` the new disk. After step 6 the old disk is out of the
volume group and its extents hold the state at the moment of the move: `vgcfgrestore` from the
archive LVM wrote before `pvmove` (`/etc/lvm/archive/pve_*.vg`) loses every write made since, and a
rebuild with [`platform-restore.md`](platform-restore.md) from the guest backups loses those since
the backup.

## Background

The old disk stays fitted and outside every volume group until its reuse is decided; wiping it
ends the rollback. Related: [guest-backup-restore.md](guest-backup-restore.md),
[lvm-thin-pool-full.md](lvm-thin-pool-full.md).
