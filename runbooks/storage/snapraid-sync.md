# Runbook: SnapRAID sync (manual)

## Problem

SnapRAID parity reflects the state of data at the last sync. After write operations, new and
modified files are unprotected until sync runs. A disk failure before sync completes means
unrecoverable data loss for all files written since the last sync.

## Preconditions

- SSH access to VM102
- SnapRAID is installed and `/etc/snapraid.conf` is present
- All data disks and parity disk are online (`lsblk` / verify mount points in `snapraid.conf`)
- No large writes are actively in progress

## Commands (VM102)

```bash
snapraid sync
```

Review output for warnings before confirming success.

---

## Verification

```bash
snapraid status
```

Expected: no unsynced differences reported. Exit code 0 indicates success.

---

## Failure Modes

| Symptom | Likely Cause | Action |
|---|---|---|
| `WARNING! Parity files are not updated.` | Sync was aborted mid-run | Re-run `snapraid sync` |
| Disk not found / missing content | Data or parity disk offline or unmounted | Check `lsblk`; verify paths in `/etc/snapraid.conf` |
| `SYNC INTERRUPTED` / I/O error | Disk read/write error | Inspect `dmesg` and `smartctl -a <disk>` |
| Large number of deleted files reported | Unexpected removal or wrong mount state | Confirm all mounts before proceeding; do not use `--force-deletions` unless verified |

## Rollback

**There is none, and that is the single most important property of this command.**

`snapraid sync` overwrites parity with the current state of the data disks. Parity is not a snapshot
and not a version history -- it is one equation over the present contents. Once the present state is
written into it, the previous state is unreachable: a file deleted, truncated or encrypted *before*
the sync cannot be recovered *after* it, by any means. There is no undo, and there is no older parity
to fall back to.

That is why all of the safety is front-loaded, and why the preconditions above are not housekeeping:

```bash
# ALWAYS run this first, and read it. It is the only rollback that exists.
snapraid diff
```

**Abort criteria -- do not sync if any of these hold:**

- `diff` reports removed or updated file counts you cannot account for. An unexplained deletion count
  is the signature of both an accidental `rm -rf` and of ransomware, and sync is the step that makes
  either one permanent.
- Any data disk is unmounted, or mounted empty. SnapRAID reads an empty disk as "every file on it was
  deleted" and will encode exactly that.
- A scrub has reported errors that have not been fixed. Sync would write the damage into parity.

`--force-deletions` exists to override the first check. Treat it as a command that destroys backups,
because in the one case where it matters, that is what it does.

---

## Notes

- Sync runs automatically via cron on VM102 (daily at 23:00). Script: `snippets/storage/snapraid-maintenance.sh sync`
- This runbook covers manual execution (ad-hoc sync after large writes, troubleshooting).
- SnapRAID is parity-based, not snapshot-based — sync must run before a failure to protect recent data.
- See: [Storage Design](../../docs/platform/storage-design.md)
- See: [VM102 node doc](../../docs/nodes/vm102.md)
