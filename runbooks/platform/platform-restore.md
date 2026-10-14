# Runbook: Platform restore onto a fresh Proxmox host

- **Use when:** the boot SSD is lost or replaced and the host is reinstalled; `plan` and
  `test-restore` also run on the live host as a backup check.
- **Duration:** `plan` and `test-restore` a few minutes; a full rebuild several hours, mostly
  restore time.
- **Risk:** a second running copy of the host's Tailscale identity makes both copies unreachable;
  `host` on a host that already has guests is refused by the script.
- **Last exercised:** never

`snippets/scripts/platform-restore.sh`, deployed by the `guest_backup` role to
`/usr/local/sbin/`, rebuilds the host from two archive sets in `/mnt/vzdump`:

| Source | Content |
|---|---|
| `host-config-backup.sh`, daily | `/etc` with `/etc/pve`, the cluster database, CIFS credentials, root's keys, `/var/lib/tailscale`, `/usr/local`, guest configurations, machine metadata; to `/mnt/vzdump/host-config` and `/var/backups/host-config`. Watched by `HostConfigBackupStale`. |
| `guest-backup.sh`, weekly | `vzdump` of all nine guests; vm100's data disk excluded by `backup=0` ([guest-backup-restore.md](guest-backup-restore.md)). |

Subcommands: `plan` (read-only), `test-restore <ctid>`, `host`, `guests`, `verify`. `guests`
restores and starts in the order `ORDER=(102 260 200 210 211 220 230 250 100)`: vm102 first,
because the host's CIFS mounts and lxc260, lxc210 and lxc220 need its shares; vm100 last, with its
data disk reattached from the aux-disk.

## Preconditions

- The disk holding `/mnt/vzdump` (the aux-disk, [KE-13](../../docs/platform/known-errors.md#ke-13))
  survived. If not, `/var/backups/host-config` on the old boot disk still has the host
  configuration, but no guest archive exists anywhere else
  ([off-site backup](../../docs/platform/remediation-plan.md#off-site-backup)).
- Proxmox VE of the same major version installed on the new boot disk, hostname `server`, `vmbr0`
  on the same network as before.
- The old host is off.

## Steps

1. On the old host while it still runs, prove the backups. Both commands are safe on the live host.
   ```bash
   platform-restore.sh plan
   platform-restore.sh test-restore 260
   ```
   Check: `plan complete, no gaps`; `test-restore of 260 passed` (restored as 960, mounted,
   destroyed, never started).
2. On the new installation, mount the backup disk by hand; its fstab line is inside the archive.
   ```bash
   mkdir -p /mnt/aux-disk && mount /dev/disk/by-id/<aux-disk>-part1 /mnt/aux-disk
   mkdir -p /mnt/vzdump && mount --bind /mnt/aux-disk/vzdump /mnt/vzdump
   ```
   Check: `ls /mnt/vzdump/host-config/` lists `host-config-*.tar.zst`.
3. Extract the tool from the newest archive (or take it from the repository).
   ```bash
   A=$(ls /mnt/vzdump/host-config/host-config-*.tar.zst | tail -1)
   tar --zstd -xOf "$A" usr/local/sbin/platform-restore.sh > /root/platform-restore.sh
   chmod 700 /root/platform-restore.sh
   ```
   Check: `/root/platform-restore.sh plan` prints the saved and current Proxmox versions.
4. Restore the host configuration, then reboot for IOMMU and vfio.
   ```bash
   /root/platform-restore.sh host
   reboot
   ```
   Check: `host step done`; after the reboot `findmnt /mnt/vzdump` and `ls /mnt/smb` answer once
   vm102 runs. A `network configuration differs` line is compared by hand, not applied.
5. Restore and start the guests.
   ```bash
   /root/platform-restore.sh plan
   /root/platform-restore.sh guests
   /root/platform-restore.sh verify
   ```
   Check: `plan` shows every passthrough disk `present`; `verify` lists all nine guests running.
6. From lxc250: every playbook that targets the `proxmox` group, then `fleet-health-check.yml` and
   a drift sweep.
   Check: no failed hosts; the sweep reports no drift.

## Verification

- `qm config 102` names all seven passthrough disks; `qm config 100` has `scsi1`.
- On the host: `ls /mnt/smb/*` answers, `systemctl --failed` is empty, `uname -r` is the expected
  kernel.
- `fleet-health-check.yml` green; no alert other than `Watchdog`.
- Tailscale admin console: one `server` node, not two.

## Failure modes

| Symptom | Cause | Action |
|---|---|---|
| `plan`: `<id>: NO ARCHIVE` | Weekly run failed for it, or the guest is not in `GUESTS` | Check `GuestBackupPartial`; add a new guest to `guest-backup.sh` and `ORDER` |
| `plan`: `on the saved host but not in ORDER` | Guest added without updating the script | Add it to `ORDER` |
| `host`: `guests exist on this host` | Not a fresh installation | Intended; restore single guests with `guests`, which skips existing IDs |
| `MISSING <key>: ... left out` | A passthrough disk or the aux-disk is not attached | Attach it; `qm set <id> --<key> <value>` with the line from `meta/guest-conf/` |
| lxc260, lxc210 or lxc220 do not start | vm102's shares not reachable yet | `ls /mnt/smb/postgres-backups`, then `pct start <ctid>` |
| `server` appears twice in Tailscale | Old host running | Power it off; remove the stale node in the console |

## Rollback

The old boot disk is not touched. Put it back and boot; the platform is as at its last shutdown,
and whatever the new disk's guests wrote is discarded with it.

## Background

The host configuration is what a guest archive does not carry: fstab entries for the data disks
and CIFS mounts, their credential files, IOMMU kernel arguments and vfio bindings for vm100's GPU,
the storage definitions the guest configurations name, units under `/etc/systemd/system`, and the
Tailscale node identity. `host` appends only the saved `/mnt/` fstab lines and missing
`storage.cfg` stanzas, so the installer's root, EFI and swap entries stay. Related:
[boot-ssd-replacement.md](boot-ssd-replacement.md), [lxc250-rebuild.md](lxc250-rebuild.md),
[KE-14](../../docs/platform/known-errors.md#ke-14).
