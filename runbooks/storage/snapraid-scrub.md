# Runbook: SnapRAID scrub (manual)

- **Use when:** `SnapRAIDScrubStale`, `SnapRAIDScrubCoverageAging` or `SnapRAIDArrayUnscrubbed`
  fires, a disk shows new SMART errors, or a scheduled scrub reported errors.
- **Duration:** scales with the share of the array read; a full scrub takes hours.
- **Risk:** low; scrub only reads and updates its own bookkeeping. The risk is the follow-up: running
  `snapraid sync` over reported errors writes the damage into parity.
- **Last exercised:** never.

Scrub reads data blocks and compares them with parity, so silent corruption is found while parity
can still repair it. It runs weekly by `snapraid-scrub.timer` (role `snapraid_maintenance`;
schedule and the share per run, `snapraid_scrub_percent`, in its defaults; `Persistent=true`),
which starts `snapraid-maintenance@scrub.service` and runs `snapraid scrub -p <percent>`. Each run
verifies the oldest blocks first. `SnapRAIDScrubStale` fires after 10 days without a successful
scrub, `SnapRAIDScrubCoverageAging` when the oldest block is older than 200 days.

All commands run on vm102 as root (`ssh <user>@<tailscale-ip-storage>`, then `sudo -i`).

## Preconditions

- Every data disk (disk01..N) and the parity disk are mounted (`findmnt` for each path in
  `/etc/snapraid.conf`).
- Parity is current: `snapraid status` shows no unsynced differences, otherwise run
  [snapraid-sync.md](snapraid-sync.md) first. Changed files cannot be verified.
- No large writes are in progress.

## Steps

1. Read the current coverage.
   ```bash
   snapraid status
   ```
   Check: the oldest scrubbed block age and the unscrubbed share; no bad blocks reported yet.

2. Run a scrub through the unit, so the metrics are written.
   ```bash
   systemctl start snapraid-maintenance@scrub.service
   journalctl -u snapraid-maintenance@scrub.service -n 30 --no-pager
   ```
   For a larger share by hand: `snapraid scrub -p <percent>` (no metric is written).
   Check: `OK: snapraid scrub of <n>% completed at <date> in <s>s`; no `error` lines.

3. If errors were reported, find what is affected.
   ```bash
   snapraid status
   snapraid -e check
   ```
   Check: `status` names the bad blocks; `-e check` lists the files that contain them. Note the
   disk; check `smartctl -a /dev/<disk>` and `dmesg` before repairing.

4. Repair only the blocks marked bad, then re-verify them.
   ```bash
   snapraid -e fix
   snapraid -p bad scrub
   ```
   `-e` restricts `fix` to blocks a scrub marked bad. To narrow further, add a filter:
   `-f <path>` for a file or directory, `-d <disk>` for one data disk. A plain `snapraid fix`
   without `-e` or a filter rewrites every file that differs from parity, including files changed
   since the last sync.
   Check: the re-scrub reports no errors; `snapraid status` reports no bad blocks.

## Verification

```bash
snapraid status
systemctl list-timers snapraid-scrub.timer
```

Expected: no bad blocks; the oldest block age has dropped; the timer shows a `NEXT` time. In
Prometheus, `snapraid_scrub_last_success_timestamp` has advanced and no `SnapRAIDScrub*` alert is
firing.

## Failure modes

| Symptom | Cause | Action |
|---|---|---|
| Data errors reported | Silent corruption on a data disk | Steps 3 and 4; treat as a disk-health event |
| `Error reading file`, I/O error | Read failure, early hardware fault | `smartctl -a /dev/<disk>`; `dmesg`; plan a disk replacement |
| Scrub skips blocks, parity not current | Writes since the last sync | Run [snapraid-sync.md](snapraid-sync.md) first (only if no errors are open), then scrub |
| `SnapRAIDScrubStale` | Scrub runs failed or the timer is not firing | `systemctl status snapraid-scrub.timer snapraid-maintenance@scrub.service` |
| `SnapRAIDScrubCoverageAging` while scrubs succeed | Share per run too small for the array | Raise `snapraid_scrub_percent` in the role defaults |
| `fix` reports unrecoverable blocks | More failed blocks than parity levels | Restore the listed files from another backup |

## Rollback

Not applicable for the scrub itself: it writes no file content and does not modify parity. `snapraid
fix` rewrites file content from parity and has no undo; `-e` and filters keep it to the blocks a
scrub proved bad.

Abort criterion: if a scrub reports errors, do not run `snapraid sync` to clear them. Sync would
encode the damaged state into parity and remove the ability to repair it; see
[snapraid-sync.md](snapraid-sync.md#rollback).

## Background

See [storage-design.md](../../docs/platform/storage-design.md) and
[vm102.md](../../docs/nodes/vm102.md).
