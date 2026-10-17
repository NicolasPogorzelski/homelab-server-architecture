# Runbook: Guest backup and restore (vzdump)

- **Use when:** deploying or changing the guest backup, `GuestBackupStale`, `GuestBackupPartial` or
  `GuestBackupMetricsMissing` fires, a guest has to be restored, or the quarterly restore test is
  due.
- **Duration:** 15 minutes to deploy; a test restore 10-20 minutes; a recovery restore depends on
  the archive size.
- **Risk:** `pct restore --force` / `qmrestore --force` destroy the existing guest; a restore into
  `local-lvm` can push the thin pool past its critical threshold; a restored clone that boots on the
  network takes over the original's Tailscale identity.
- **Last exercised:** 2026-08-21, pass (lxc260 restored into ID 999, not started, verified through
  `pct mount`).

The [`guest_backup`](../../ansible/roles/guest_backup/) role deploys
`snippets/scripts/guest-backup.sh` with a systemd timer on the Proxmox host (schedule in the role
defaults, `Persistent=true`). It runs `vzdump --mode snapshot` for nine guests (`GUESTS` in the
script: 250 260 210 211 200 220 230 102 100) into `/mnt/vzdump`, prunes per guest, and writes
`guest_backup_*` metrics to the node_exporter textfile directory. The same role deploys the daily
host configuration backup (see [platform-restore.md](platform-restore.md)).

## Preconditions

The role asserts 1 to 3 and refuses to deploy without them.

1. The host is in the `proxmox` inventory group; otherwise the playbook matches no host and exits 0.
2. `/mnt/vzdump` is a mountpoint on a device other than root. A missing mount would leave an empty
   directory on `pve-root` and the run would fill the boot SSD
   ([KE-7](../../docs/platform/known-errors.md#ke-7)).
3. At least 25 GB free on `/mnt/vzdump`. vzdump prunes only after a successful write, so a full
   target fails instead of rotating.
4. Every passthrough disk on a VM carries `backup=0` (not asserted; it lives in the guest config):
   ```bash
   qm config <vmid> | grep -E '^(scsi|virtio|sata)[0-9]'
   ```
   Every line naming `/dev/disk/by-id/` ends in `backup=0`. vm102's SnapRAID disks without it make
   a run try to read the whole array. vm100's data disk carries `backup=0`; the script also skips a
   VM that would pull in a disk over 128 GB without the flag.
5. For a restore: thin-pool headroom. `lvs pve/data` shows `Data%`; the VG has no free extents, so
   the pool cannot be extended. `local-lvm` is the only storage that accepts a container rootfs.

The target is bound by fstab, identified by ID, never by kernel letter:
```
/dev/disk/by-id/<disk-id>      /mnt/vzdump  ext4  defaults,nofail,noatime  0  2
/mnt/<existing-mount>/vzdump   /mnt/vzdump  none  bind,nofail              0  0
```
Use the second form for a directory on an already-mounted disk. Changing the backup disk is an fstab
change only.

## Steps

### Deploy

1. From `ansible/` on lxc250, dry run first.
   ```bash
   ansible-playbook playbooks/guest-backup.yml --check --diff
   ansible-playbook playbooks/guest-backup.yml
   ```
   Check: the mount and free-space asserts pass; a second run reports `changed=0`.
2. Run once on demand.
   ```bash
   systemctl start guest-backup.service
   journalctl -u guest-backup.service -f
   ```
   Check: every guest in `GUESTS` has a new archive in `/mnt/vzdump`; vm102 shows
   `exclude disk ... (backup=no)` for each passthrough disk.

### Test restore (quarterly; never started)

3. Pick the smallest container archive and confirm headroom.
   Check: `lvs pve/data` plus the archive size stays below the `LvmThinPoolCritical` threshold
   (`alert.rules.yml`, group `lvm`).
4. Restore into a free ID.
   ```bash
   pct restore 999 /mnt/vzdump/vzdump-lxc-<ctid>-<timestamp>.tar.zst --storage local-lvm --unprivileged 1
   ```
   Check: `pct config 999` shows the original's hostname. Do not start it.
5. Inspect without starting.
   ```bash
   pct mount 999
   R=/var/lib/lxc/999/rootfs
   grep PRETTY_NAME $R/etc/os-release
   md5sum $R/etc/<config-file>; pct exec <ctid> -- md5sum /etc/<config-file>
   ```
   Check: the OS is present and config files are byte-identical to the live guest.
6. Tear down.
   ```bash
   pct unmount 999 && pct destroy 999
   ```
   Check: `lvs pve/data` is back at the value from step 3. Record the date in the header.

### Recovery restore over the original

7. Restore the chosen archive into a free ID first and inspect it as in step 5.
   Check: the content is what is expected; then destroy the test ID.
8. Make the overwrite reversible: back up the current guest if it still runs, or keep its volume.
   ```bash
   vzdump <ctid> --dumpdir /mnt/vzdump --mode stop --compress zstd
   ```
   Check: a new `vzdump-*-<ctid>-*` archive exists. If the guest cannot be dumped, step 9 is not
   reversible; proceed only if the guest is lost anyway.
9. Overwrite.
   ```bash
   pct stop <ctid>
   pct restore <ctid> /mnt/vzdump/vzdump-lxc-<ctid>-<timestamp>.tar.zst --force --storage local-lvm
   pct start <ctid>
   ```
   For a VM: `qm stop <vmid>`, `qmrestore <archive> <vmid> --force`, `qm start <vmid>`.
   Check: the guest starts and its services pass their own checks. For lxc260 and lxc210, replay the
   newest database dump afterwards ([pg-restore.md](../database/pg-restore.md),
   [mariadb-restore.md](../database/mariadb-restore.md)): a snapshot backup of a running database is
   crash-consistent only.

## Verification

```bash
systemctl list-timers guest-backup.timer
for f in /mnt/vzdump/*.zst; do echo -n "$(basename $f): "; zstd -t "$f" 2>/dev/null && echo OK || echo FAILED; done
```

- The timer shows a `NEXT` time.
- Every archive reports `OK`. The glob covers containers (`.tar.zst`) and VMs (`.vma.zst`).
- In Prometheus, `guest_backup_last_run_timestamp_seconds` has advanced and
  `guest_backup_failed_guests` is `0`.
- Only a restore (steps 3 to 6) proves an archive is usable.

Verified 2026-08-21: lxc260 restored into 999 in 10 s (1.4 GiB, pool 82.85 -> 85.14 % and back
after teardown); Debian 12 and the PostgreSQL 15 cluster present; `postgresql.conf`, `pg_hba.conf`
and `node_exporter.service` byte-identical to live; all archives passed `zstd -t`; lxc250's archive
passed a full `tar -tf` walk and holds `hosts.yml`, `.vault_pass` and `id_ed25519`.

## Failure modes

| Symptom | Cause | Action |
|---|---|---|
| `400 Parameter verification failed. storage: missing property required by 'notes-template'` | `--notes-template` (or `protected`) used with `--dumpdir` | Remove the option; it requires `--storage` |
| `0% (... of NN TiB)`, target filling | A VM passthrough disk lacks `backup=0` | Stop the run; Precondition 4 |
| `tar: ./<path>: Cannot open: Permission denied`, one container | A path owned outside the container's UID map | `ls -lan /proc/$(lxc-info -n <ctid> -p -H)/root/<path>`; find what wrote it before changing anything ([KE-22](../../docs/platform/known-errors.md#ke-22)) |
| `is not a mountpoint - refusing` | Backup disk not mounted | `findmnt /mnt/vzdump`; the fstab entry must use by-id |
| `resolves to the root device` | Bind source on `pve-root` | Use a different physical disk |
| `vzdump <id> exited 255`, others fine | One guest failed; the run continues | `journalctl -u guest-backup.service`; usually no room for the snapshot in `pve/data` |
| `storage does not support container directories` | Restore target is not `local-lvm` | Use `--storage local-lvm` |
| `GuestBackupMetricsMissing` | Job not deployed or collector stopped | Check the unit exists |
| Timer did not fire at its slot | Host was off | `Persistent=true` runs it at the next boot |

## Rollback

Removing the job (archives stay):
```bash
systemctl disable --now guest-backup.timer
rm /etc/systemd/system/guest-backup.{service,timer} /usr/local/sbin/guest-backup.sh
rm /var/lib/node_exporter/textfile_collector/guest-backup.prom
systemctl daemon-reload
```
Remove the `backup` alert group in the same change, or `GuestBackupMetricsMissing` fires.

A test restore is undone by step 6. A recovery restore is undone by restoring the safety archive
from step 8 the same way.

## Background

The backups share a failure domain with their alerts: Prometheus runs on lxc200 on the same host,
so the stale alerts mean "no backup within 10 days of uptime". The target is on site; the off-site
copy is not in place yet ([remediation plan](../../docs/platform/remediation-plan.md)). Never boot a
restored clone on the network; if it has to run, set `link_down=1` on `net0` and use `pct exec`.
Related: [lvm-thin-pool-full.md](lvm-thin-pool-full.md),
[KE-14](../../docs/platform/known-errors.md#ke-14) (the boot SSD that holds every guest).
