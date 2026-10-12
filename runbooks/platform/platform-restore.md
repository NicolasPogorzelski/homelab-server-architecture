# Runbook: Platform restore onto a fresh Proxmox host

## Problem

The guest backup restores machines, and only onto a host that already looks like this one. The
host itself was in no backup: the fstab entries for the data disks and the CIFS mounts, the
credential files those mounts read, the IOMMU kernel arguments and vfio bindings for vm100's GPU,
the storage definitions the guest configurations name, the hand-written units under
`/etc/systemd/system` and the Tailscale node identity. Losing the boot SSD meant reinstalling
Proxmox and then rebuilding the host from memory before the first guest could start. A single
archive from 2026-08-20 existed, by hand, on that same SSD.

## Solution

Three pieces, all from the `guest_backup` role:

| Piece | What it does |
|---|---|
| `host-config-backup.sh` | Daily archive of `/etc` (with `/etc/pve`), the cluster database, CIFS credentials, root's keys, `/var/lib/tailscale`, `/usr/local`, the guest configurations and the machine's metadata, written to `/mnt/vzdump/host-config` and `/var/backups/host-config`. `HostConfigBackupStale` watches it. |
| `guest-backup.sh` | Weekly `vzdump` of every guest, vm100 included since 2026-10-12 with its data disk excluded by `backup=0`. |
| `platform-restore.sh` | Reads both and rebuilds: `plan`, `test-restore`, `host`, `guests`, `verify`. |

Order of a rebuild: vm102 first, because the host's CIFS mounts and three containers need its
shares; lxc260 next, the database; lxc250 late, because it runs Ansible once the rest is up; vm100
last, with its data disk reattached from the auxiliary disk.

## Precondition

- The disk holding `/mnt/vzdump` survived: the auxiliary disk (KE-13) today. If it did not, the
  copy in `/var/backups/host-config` on the old boot disk has the host configuration, and no
  guest archive exists anywhere else - see the off-site item in the remediation plan.
- A Proxmox VE installation of the same major version on the new boot disk, hostname `server`,
  the bridge `vmbr0` on the same network as before.
- The old host is off. The restore brings back its Tailscale identity; two running copies of one
  node key make both unreachable.

## Procedure

Prove the backups first. Both commands are safe on the running host, and the second is the only
restore test this platform can run without a second machine.

```bash
platform-restore.sh plan                 # every guest has an archive, every disk is present
platform-restore.sh test-restore 260     # smallest container: restore as 960, mount, destroy
```

On the new installation:

```bash
# 1. The backup disk. Its fstab line is in the archive, but the archive is on it.
mkdir -p /mnt/aux-disk && mount /dev/disk/by-id/<aux-disk>-part1 /mnt/aux-disk
mkdir -p /mnt/vzdump && mount --bind /mnt/aux-disk/vzdump /mnt/vzdump

# 2. The tool, from the newest archive (or from the repository)
A=$(ls /mnt/vzdump/host-config/host-config-*.tar.zst | tail -1)
tar --zstd -xOf "$A" usr/local/sbin/platform-restore.sh > /root/platform-restore.sh
chmod 700 /root/platform-restore.sh

# 3. Read before writing
/root/platform-restore.sh plan

# 4. Host configuration, then a reboot for IOMMU and vfio
/root/platform-restore.sh host
reboot

# 5. Guests, in order, started as they come
/root/platform-restore.sh plan
/root/platform-restore.sh guests
/root/platform-restore.sh verify
```

Then, from lxc250: every playbook that targets the `proxmox` group, so the roles own the host
again, followed by `fleet-health-check.yml` and a drift sweep.

## Verification

- `platform-restore.sh verify`: every guest listed and running.
- `qm config 102` names all seven passthrough disks, `qm config 100` its `scsi1`.
- On the host: `ls /mnt/smb/*` answers, `systemctl --failed` is empty, `uname -r` is the expected
  kernel.
- The fleet: `fleet-health-check.yml` green, the drift sweep reports nothing, no alert but
  `Watchdog`.
- On the Tailscale console: one `server` node, not two.

## Failure

| Symptom | Cause | Action |
|---|---|---|
| `plan` reports `NO ARCHIVE` for a guest | The weekly run failed for it, or it was never in `GUESTS` | Check `GuestBackupPartial`; for a new guest, add it to `guest-backup.sh` |
| `host` refuses: guests exist | Not a fresh installation | Intended. Restore single guests with `guests`, which skips existing ones |
| `reattach ... MISSING` | A passthrough disk or the auxiliary disk is not attached | Attach it, then `qm set <id> --<key> <value>` with the line from `meta/guest-conf/` |
| lxc260 or lxc210 fail to start | vm102's shares not yet reachable | `ls /mnt/smb/postgres-backups`, then `pct start` |
| The node shows up twice in Tailscale | The old host is running | Power it off; remove the stale node in the console |

## Rollback

Nothing on the old boot disk is touched. Put it back, boot it, and the platform is as it was at its
last shutdown; the guests on the new disk are discarded with it.

## Related

- [Guest backup and restore](guest-backup-restore.md)
- [Boot SSD replacement](boot-ssd-replacement.md)
- [LXC250 rebuild](lxc250-rebuild.md)
- [KE-14](../../docs/platform/known-errors.md#ke-14), [KE-13](../../docs/platform/known-errors.md#ke-13)
