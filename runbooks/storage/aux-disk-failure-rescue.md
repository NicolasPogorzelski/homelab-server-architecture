# Runbook: rescue data from a failing aux-disk (read-only)

- **Use when:** the host aux-disk (`/mnt/aux-disk`) logs unrecoverable medium errors or no longer
  mounts at boot, and guests that bind subdirectories of it fail to start.
- **Duration:** hours; dominated by copy speed and retries on bad sectors.
- **Risk:** any write to the dying disk (read-write mount, `fsck`, journal replay) can destroy what
  is still readable. Every step here is read-only against the disk.
- **Last exercised:** 2026-06-25, applied in the aux-disk incident; data copied off with the read
  errors enumerated.

Rescue before repair: no `fsck` and no read-write mount on a disk with pending or uncorrectable
sectors until the data is copied off and verified. See
[KE-13](../../docs/platform/known-errors.md#ke-13) and the
[incident report](../../docs/platform/incidents/2026-06-25-aux-disk-failure-and-recovery.md).

## Preconditions

- Root shell on the Proxmox host, from the rescue target: `ssh root@<lan-ip-proxmox>` (or the
  Tailscale address).
- The disk identified by UUID, not `/dev/sdX` (device names renumber).
- A hardware fault, not cabling:
  ```bash
  dmesg | grep -iE 'medium error|unrecovered read error'
  smartctl -A /dev/<disk> | grep -iE 'Pending|Uncorrect|Reallocated'
  ```
  `Current_Pending_Sector` or `Offline_Uncorrectable` in the thousands means decommission.
- A healthy rescue target with enough free space (the admin workstation on a wired path). `tar`
  archives carry ownership, so the target filesystem does not have to.
- No writer holds the disk: the fstab entry is `nofail`, and `findmnt /mnt/aux-disk` shows no
  read-write mount. Stop the guests that bind it (`grep aux-disk /etc/pve/lxc/*.conf`).

## Steps

1. Mount read-only without journal replay.
   ```bash
   mount -o ro,noload UUID=<aux-disk-uuid> /mnt/aux-disk
   findmnt -no OPTIONS /mnt/aux-disk
   ls /mnt/aux-disk
   ```
   Check: the options start with `ro`; the directory tree is visible. If the mount fails, the
   metadata is damaged: go to the `ddrescue` row in Failure modes.

2. If a directory holds a VM disk image, loop-mount it read-only as well.
   ```bash
   mkdir -p /mnt/peek
   mount -o ro,noload,loop /mnt/aux-disk/images/<vmid>/<disk>.raw /mnt/peek
   ```
   Check: `findmnt -no OPTIONS /mnt/peek` starts with `ro`.

3. Copy off, one archive per directory, most valuable first (databases and configuration before
   regenerable data). Run on the rescue target, pulling from the host:
   ```bash
   mkdir -p ~/aux-disk-rescue && cd ~/aux-disk-rescue
   for d in <dir1> <dir2> <dir3>; do
     ssh root@<lan-ip-proxmox> \
       "tar -C /mnt/aux-disk --numeric-owner --ignore-failed-read -cf - $d" \
       > "$d.tar" 2> "$d.err"
     echo "$d -> $(du -h "$d.tar" | cut -f1)"
   done
   ```
   For data inside a loop-mounted image, use `tar -C /mnt/peek` the same way.
   Check: one `.tar` and one `.err` per directory; no archive is 0 bytes.

4. Enumerate what the disk could not return.
   ```bash
   grep -v 'socket ignored' *.err
   for t in *.tar; do tar -tf "$t" >/dev/null && echo "$t OK" || echo "$t CORRUPT"; done
   ```
   Check: every archive `OK`. Remaining `.err` lines are real read failures; record those files.

## Verification

- `tar -tf` exits 0 for every archive.
- Real read errors are zero, or the lost files are listed and accepted.
- A critical artifact is inside its archive, for example
  `tar -tvf <db-dir>.tar | grep 'PG_VERSION\|/main/'`.
- Rescued size matches the live data, not the allocated size; sparse VM images inflate the latter
  and `tar` copies only live data.

## Failure modes

| Symptom | Cause | Action |
|---|---|---|
| `ro,noload` mount fails | Filesystem metadata damaged | `ddrescue` the whole partition onto a healthy disk, then `fsck` the image, never the disk |
| `tar` stalls for seconds | Kernel retrying a bad sector | Wait; `--ignore-failed-read` continues after the timeout |
| `Input/output error` in `.err` | Unreadable sectors | Record the files; restore them from another backup if one exists |
| Rescue target fills up | Regenerable data included | Exclude container layers, model caches and media; copy databases, configs and metadata |

## Rollback

Not applicable: the procedure is read-only against the failing disk. Remove the transient mounts
when done:

```bash
umount /mnt/peek 2>/dev/null
umount /mnt/aux-disk
```

A repair attempt (`fsck`) or decommissioning starts only after the rescued data is verified.

## Background

The rescue uses `tar`: ownership and permissions are stored inside the archive, so the receiver
needs no root and container-mapped UIDs are restored exactly later (`--numeric-owner`, because those
IDs have no names on the rescue target). `--ignore-failed-read` keeps one unreadable file from
aborting the archive. One archive per directory means an interruption or one bad directory loses
nothing else. `ro,noload` mounts read-only without replaying the ext4 journal, which would write.
