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

---

## Notes

- Sync runs automatically via cron on VM102 (daily at 02:00). Script: `snippets/storage/snapraid-maintenance.sh sync`
- This runbook covers manual execution (ad-hoc sync after large writes, troubleshooting).
- SnapRAID is parity-based, not snapshot-based — sync must run before a failure to protect recent data.
- See: [Storage Design](../../docs/platform/storage-design.md)
- See: [VM102 node doc](../../docs/nodes/vm102.md)
