# Runbook: SnapRAID sync (manual)

- **Use when:** large writes to the vm102 array need protection before the next timer run,
  `SnapRAIDSyncStale` fires, or the nightly sync failed.
- **Duration:** minutes for a small delta; hours after large writes.
- **Risk:** irreversible. Sync overwrites parity with the current state of the data disks; a file
  deleted, truncated or encrypted before the sync cannot be recovered after it.
- **Last exercised:** never.

Parity reflects the data at the last sync; files written since are unprotected. The sync runs
daily by `snapraid-sync.timer` (role `snapraid_maintenance`, schedule in its defaults,
`Persistent=true`), which starts `snapraid-maintenance@sync.service`:
`snippets/storage/snapraid-maintenance.sh sync` runs `snapraid touch`, then `snapraid sync`, and
writes `snapraid_sync_last_success_timestamp`. The timer has no `diff` gate; a manual run does.

All commands run on vm102 as root (`ssh <user>@<tailscale-ip-storage>`, then `sudo -i`).

## Preconditions

- `/etc/snapraid.conf` is present and parses: `snapraid devices` exits 0.
- Every data disk (disk01..N) and the parity disk are mounted and not empty: compare `findmnt`
  for each path in `snapraid.conf` with the list in the file.
- No large writes are in progress.
- No unfixed scrub errors: `snapraid status` reports no bad blocks. Otherwise go to
  [snapraid-scrub.md](snapraid-scrub.md) first; sync would write the damage into parity.

## Steps

1. Review what the sync would encode. This is the only rollback point.
   ```bash
   snapraid diff
   ```
   Check: the `removed` and `updated` counts match changes you can account for. Stop on an
   unexplained deletion count; it is the signature of both an accidental `rm -rf` and ransomware,
   and sync makes either permanent.

2. Run the sync through the unit, so the metric is written.
   ```bash
   systemctl start snapraid-maintenance@sync.service
   journalctl -u snapraid-maintenance@sync.service -n 30 --no-pager
   ```
   Check: `OK: snapraid sync completed at <date> in <n>s`; the unit result is `success`.

## Verification

```bash
snapraid status
systemctl list-timers snapraid-sync.timer
```

Expected: no unsynced differences, no bad blocks; the timer shows a `NEXT` time. In Prometheus,
`snapraid_sync_last_success_timestamp` has advanced and `SnapRAIDSyncStale` is not firing.

## Failure modes

| Symptom | Cause | Action |
|---|---|---|
| `WARNING! Parity files are not updated.` | Previous sync aborted mid-run | Step 1, then step 2 |
| Disk not found, missing content | Data or parity disk not mounted | `findmnt` for the path; `lsblk`; fix the mount before anything else |
| Sync refuses: all files on a disk missing | A data disk is mounted empty | Mount the disk. Never pass `--force-empty` unless the disk is really meant to be empty |
| `SYNC INTERRUPTED`, I/O error | Disk read or write error | `dmesg`; `smartctl -a /dev/<disk>`; SMART series from `smart_metrics` in Prometheus |
| `Unexpected size change at file ...`, then `N file errors`, `0 io errors`, `0 data errors` | A live application file changed during the read; not media and not corruption | Re-running recurs. Add the path to `snapraid_excludes` in the role defaults and apply the role ([KE-19](../../docs/platform/known-errors.md#ke-19)) |
| Exit 1 and `SnapRAIDSyncStale` although parity looks current | One unprotectable file fails the run, so no metric is written | Read the error lines, not the alert; same class as KE-19 |

## Rollback

None. Parity is one equation over the present contents, not a snapshot; once written, the previous
state is unreachable. The safety is front-loaded.

Abort criteria, do not sync if any holds:

- `snapraid diff` reports removed or updated counts you cannot account for.
- A data disk is unmounted or mounted empty. SnapRAID reads an empty disk as every file on it
  deleted.
- A scrub reported errors that are not fixed.

## Background

The exclude rules in `/etc/snapraid.conf` are owned by the role (`snapraid_excludes`, written as a
managed block); the rest of the file is not. Exclude what changes while the array is read, not what
shares a suffix. See [storage-design.md](../../docs/platform/storage-design.md) and
[vm102.md](../../docs/nodes/vm102.md).
