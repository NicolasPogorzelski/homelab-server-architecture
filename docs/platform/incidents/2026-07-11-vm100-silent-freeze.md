# Incident & Recovery: VM100 Silent Guest Hard-Freeze (2026-07-11)

vm100 (GPU passthrough node) hard-froze overnight and was found about 8 hours later, unreachable
over every network path. It was recovered by a hard power cycle. The root cause is undetermined
from logs. Recorded as [KE-17](../known-errors.md#ke-17).

## Summary

| # | Problem | Outcome |
|---|---|---|
| 1 | vm100 unreachable over SSH and Tailscale | Guest hard-frozen; recovered with `qm stop`/`qm start` |
| 2 | Root cause of the freeze | Undetermined; host disk layer ([KE-14](../known-errors.md#ke-14)) and host OOM/vfio/nvidia excluded |
| 3 | Freeze unnoticed for about 8 hours | `NodeDown` fired 4 minutes after the freeze; nobody responded overnight and nothing recovered automatically |

## 1 - Diagnosis path

Evidence was captured before any hard reset.

| Step | Command | Result |
|---|---|---|
| SSH fails | `ssh -v gpu` | hangs at `Connecting to <tailscale-ip-vm100> port 22`: reachability, not refused or auth |
| VM state | `qm status 100` | `running` - hypervisor scheduling, not guest health |
| Tailnet view | `tailscale status` | `gpu-vm ... offline, last seen 8h ago, tx ... rx 0`: host sends, guest never replies |
| Graceful reboot | web UI reboot | `QEMU Guest Agent is not running - guest-ping got timeout`; `powerdown failed - got timeout` |
| Scope | (above) | guest agent and ACPI both dead: the whole guest OS is wedged, not only `tailscaled` |
| Console | `qm terminal 100` | blank - no login prompt, no echo, no panic trace |

Diagnosis: silent guest-internal hard freeze. The QEMU process kept running while the guest kernel
was wedged, which is why `qm status` read `running`.

## 2 - Why the logs name no cause

- Guest journal (`journalctl -b -1`) ends at `01:41:13 UTC` during normal operation, with no
  shutdown sequence. A grep for `oom|hung task|soft lockup|BUG:|call trace|watchdog` found only the
  boot-time `NMI watchdog: Enabled`.
- Host journal 03:30-03:50 CEST: no `kvm`, `vfio`, `nvidia`, `oom` or VMID-100 message; the SMART
  textfile collector completed at 03:41. The host disk and HBA layer logged nothing
  ([KE-14](../known-errors.md#ke-14) excluded).
- The in-guest NMI watchdog was enabled and caught nothing: under KVM it depends on PMU counters
  that are virtualized unreliably.

### Clock offset

The guest runs `Etc/UTC`, the host `Europe/Berlin` (CEST, +2 h), both confirmed with
`timedatectl`. Read without the offset, the guest's last line (`01:41`) falls inside the host's
power-off gap (host boot -1 ended `01:01:10 CEST`, boot 0 began `01:58:09 CEST`), which is
impossible. With the offset the freeze is at 03:41 CEST, inside host boot 0, consistent with
`tailscale`'s "last seen ~8h ago" and with the `NodeDown` time. The host was up outside its
schedule because it had been switched on by hand that night; `homelab_schedule` was not at fault.
`journalctl --list-boots` and `uptime` on the host separated the power-off gap from a logging gap.

## 3 - Recovery

Graceful paths had failed (guest agent ping and ACPI powerdown timed out), so:

```
qm stop 100    # QMP quit attempt, then the QEMU process is killed
qm start 100   # fresh QEMU process; guest boots
```

The node returned to `active; direct` within about 2 minutes. With the host disk layer clean, the
journal replay after the unclean stop was low-risk. `ssh gpu` worked again and all alerts resolved.

## 4 - Detection and response

| Time (CEST) | Alert | Note |
|---|---|---|
| 02:02 | `NodeDown` firing, then resolved | boot transient after the manual power-on |
| 03:45 | `NodeDown`, `ServiceDown` jellyfin, `ServiceDown` audiobookshelf | the freeze, about 4 minutes after 03:41 |
| 07:50 | same, re-notified | Alertmanager `repeat_interval`, still firing |
| 11:45 | all resolved | after `qm stop`/`qm start` |

The alert reached Discord at 03:45 and stayed firing for about 8 hours. There is no overnight
escalation and no automatic recovery. A `qm status` of `running` is not a guest health check; the
guest agent ping and the serial console are.

## State after recovery

- vm100 up (`active; direct`, load about 0.04, memory about 4 %); all vm100 alerts resolved.
- No configuration changed. The cause remains open.

## Follow-up items

- Automatic recovery - open: QEMU watchdog device (`i6300esb`) plus `softdog` in the guest, to
  reset a wedged guest. The in-guest NMI watchdog is not a substitute ([KE-17](../known-errors.md#ke-17)).
- Forensics that survive a freeze - partly done: vm100's kernel log streams to the host by
  netconsole (`netconsole` role, [KE-20](../known-errors.md#ke-20)); `kdump`/`pstore` are not set up.
- Recurrence - one occurrence on record. On a repeat, investigate the NVIDIA path first
  ([KE-10](../known-errors.md#ke-10)).
- SMART monitoring documentation - done: the host collector found during this incident was
  replaced by the `smart_metrics` role on 2026-09-15 ([KE-13](../known-errors.md#ke-13),
  [monitoring](../monitoring.md)).

## Configuration changes

None. Recovery only (`qm stop 100`, `qm start 100`).

## Related documents

- [KE-17 - this incident's known-error entry](../known-errors.md#ke-17)
- [KE-10 - Jellyfin loses CUDA access (same node, NVIDIA path)](../known-errors.md#ke-10)
- [KE-14 - boot SSD I/O errors (excluded here)](../known-errors.md#ke-14)
- [KE-8 - the service probes that alerted](../known-errors.md#ke-8)
- [vm100](../../nodes/vm100.md)
- [Proxmox host](../proxmox-host.md)
