# Runbook: SnapRAID scrub (manual)

## Problem

SnapRAID scrub verifies data integrity by reading all data blocks and comparing them against
parity. Without periodic scrubbing, silent data corruption (bit rot) on data disks goes
undetected until a disk failure reveals the damage is irrecoverable.

## Preconditions

- SSH access to VM102
- Parity is current — run `snapraid sync` first if recent writes have occurred
- All data and parity disks are online (`lsblk` / verify mount points in `snapraid.conf`)
- No large writes are actively in progress

## Commands (VM102)

```bash
# Confirm parity is current before scrubbing
snapraid status

# Run scrub
snapraid scrub
```

---

## Verification

```bash
snapraid status
```

Expected: no errors or hash mismatches reported. Exit code 0 indicates success.

---

## Failure Modes

| Symptom | Likely Cause | Action |
|---|---|---|
| Hash mismatch reported | Silent data corruption (bit rot) | Run `snapraid fix` to attempt parity-based recovery; inspect affected files |
| `Error reading file` / I/O error | Disk read failure or early hardware fault | Check `smartctl -a <disk>`; inspect `dmesg` |
| Scrub aborted — parity not current | Sync was skipped after recent writes | Run `snapraid sync`, then retry scrub |
| Very slow completion | Full read of all data blocks on large pool | Normal behavior; no action required |

---

## Notes

- Scrub is currently run **manually** on an intended monthly cadence. No automation is in place.
- Automation planned: weekly cadence once file churn stabilizes.
- A hash mismatch is a critical signal — begin disk health investigation immediately; do not defer.
- See: [Storage Design](../../docs/platform/storage-design.md)
- See: [VM102 node doc](../../docs/nodes/vm102.md)
