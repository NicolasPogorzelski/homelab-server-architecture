# Runbook: Rescue Data From a Failing Aux Disk (Read-Only)

## Problem

An auxiliary disk (here: the host Aux1TB, `/mnt/aux1TB`) is throwing unrecoverable
medium errors and will not mount on boot. Services that bind-mount subdirectories
of it (Docker data-roots, VM disk images) fail to start. The disk is failing
**hardware**, not just a dirty filesystem — so the goal is to get the data off
**before** any repair attempt, then decommission.

This is the procedure used on 2026-06-25; see
[KE-13](../../docs/platform/known-errors.md#ke-13-aux1tb-physical-disk-failure-medium-errors)
and the
[incident write-up](../../docs/platform/incidents/2026-06-25-aux1tb-failure-and-recovery.md).

**Golden rule: rescue before repair.** Never run `fsck` or a read-write mount on a
disk with pending/uncorrectable sectors until the data is safely copied off. A
read-write `fsck` writes to dying media and can finish it off or "repair" metadata
into data loss.

## Preconditions

- SSH access to the Proxmox host: `ssh root@<lan-ip-proxmox-host>` (or Tailscale).
- The failing disk identified by UUID/label (not just `/dev/sdX`, which can renumber).
- Confirmed it is a **hardware** fault, not cabling — kernel log shows medium errors:
  ```bash
  dmesg | grep -iE 'medium error|unrecovered read error'
  smartctl -A /dev/<disk> | grep -iE 'Pending|Uncorrect|Reallocated'
  ```
  `Current_Pending_Sector` / `Offline_Uncorrectable` in the thousands = decommission.
- A healthy rescue target with enough free space (here: the admin notebook over a
  wired LAN path). The target must preserve Linux ownership — use `tar` archives so
  it does not have to.
- No writer holds the disk. The host fstab entry should already be `nofail` (so the
  boot is not blocked); confirm the disk is **not** mounted read-write anywhere.

## Diagnosis

Confirm the filesystem is still readable read-only (the rescue window):

```bash
mount -o ro,noload UUID=<aux1tb-uuid> /mnt/aux1TB
ls /mnt/aux1TB && df -h /mnt/aux1TB
```

- `ro,noload` mounts read-only **without** replaying the journal — no writes to the
  dying disk. If this succeeds and the tree is visible, the metadata survived and
  file-level rescue is possible.
- If a subdirectory is itself a VM disk image, loop-mount it read-only too:
  ```bash
  mount -o ro,noload,loop /mnt/aux1TB/images/<vmid>/<disk>.raw /mnt/peek
  ```

## Recovery

### Copy off, ownership-preserving, most-valuable-first

Stream each directory as a `tar` over SSH to the rescue target. Run **from the
rescue host** (here the notebook), pulling from the Proxmox host:

```bash
mkdir -p ~/aux1tb-rescue && cd ~/aux1tb-rescue
for d in postgres nextcloud calibreweb monitoring paperless; do
  ssh root@<lan-ip-proxmox-host> \
    "tar -C /mnt/aux1TB --numeric-owner --ignore-failed-read -cf - $d" \
    > "$d.tar" 2> "$d.err"
  echo "$d -> $(du -h "$d.tar" | cut -f1)"
done
```

- `tar` (not file-level `rsync`): ownership/permissions are stored **inside** the
  archive, so the receiver needs no root and exact UIDs are restored later.
- `--numeric-owner`: store numeric UID/GID (container-mapped IDs do not exist as
  names on the rescue host).
- `--ignore-failed-read`: a single unreadable file (bad sector) does not abort the
  whole archive; it is logged to `*.err` instead.
- Per-directory archives: an interruption (or one bad directory) does not lose the
  others; ordering puts the irreplaceable data first.

For data inside a loop-mounted VM image, `tar -C /mnt/peek ...` the same way.

### Check what (if anything) hit a bad sector

```bash
grep -v 'socket ignored' *.err    # 'socket ignored' = runtime sockets, not data loss
for t in *.tar; do tar -tf "$t" >/dev/null && echo "$t OK" || echo "$t CORRUPT"; done
```

Only non-`socket ignored` lines are real read failures; those files are the ones
the dying disk could not return.

## Verification

- Every archive lists cleanly: `tar -tf <archive>.tar` exits 0 for all.
- Real read errors are zero (or the lost files are enumerated and accepted).
- Spot-check a critical artifact is inside its archive, e.g.:
  ```bash
  tar -tvf postgres.tar | grep 'PG_VERSION\|/main/'
  ```
- Total rescued size matches the live (not allocated) data — sparse VM images
  inflate the "allocated" figure; file-level `tar` copies only live data.

## Failure modes

| Symptom | Check / fix |
|---|---|
| `ro,noload` mount fails | Filesystem metadata itself is damaged — escalate to `ddrescue` of the whole partition onto a healthy disk, then `fsck` the **image**, never the disk |
| `tar` stalls for many seconds | Kernel retrying a bad sector; it continues after the timeout with `--ignore-failed-read`. Expect slow spots near damaged regions |
| `*.err` shows real `Input/output error` lines | Those files are unrecoverable from this disk; record them, restore from another backup if one exists |
| Rescue target fills up | Exclude regenerable/media data (containerd layers, model caches, ebook files) — copy only databases/configs/metadata |

## Rollback / abort

No rollback needed — the entire procedure is read-only against the failing disk.
Clean up the transient mounts when done:

```bash
umount /mnt/peek 2>/dev/null
umount /mnt/aux1TB
```

Only **after** the rescued data is verified should a repair attempt (`fsck`) or
decommission proceed.
