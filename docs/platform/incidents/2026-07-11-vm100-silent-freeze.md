# Incident & Recovery: VM100 Silent Guest Hard-Freeze (2026-07-11)

VM100 (the GPU / NVIDIA-passthrough node) hard-froze overnight and was found ~8 h later,
unreachable over every network path. It was recovered by a hard power-cycle. The root cause is
**undetermined from logs** and is recorded as such; the durable value of the session is in what was
excluded, in the timeline forensics, and in confirming that detection worked while response did not.

Recorded as [KE-17](../known-errors.md#ke-17).

## Summary

| # | Problem | Outcome |
|---|---|---|
| 1 | vm100 unreachable over SSH + Tailscale | Guest hard-frozen; recovered via `qm stop`/`qm start` |
| 2 | Root cause of the freeze | **Undetermined from logs**; KE-14 (host disk) and host OOM/vfio/nvidia excluded |
| 3 | Freeze went ~8 h unnoticed | Detection was correct (`NodeDown` +4 min); the gap was human + no auto-recovery |

## 1 — Diagnosis path (symptom → verification → diagnosis)

Followed the reachability model **reachability = binding × network × firewall** and the root-cause
discipline symptom → verification → diagnosis, without hard-resetting until evidence was captured.

| Step | Command | Result |
|---|---|---|
| SSH fails | `ssh -v gpu` | hangs at `Connecting to <tailscale-ip-vm100> port 22` → reachability class, not `refused`/auth |
| Node alive? | `qm status 100` | `running` — but that is hypervisor scheduling, not guest health |
| Tailnet view | `tailscale status` | `gpu-vm … offline, last seen 8h ago, tx … rx 0` — host sends, guest never replies |
| Graceful reboot | WebUI reboot | `QEMU Guest Agent is not running — guest-ping got timeout`; `powerdown failed — got timeout` |
| Guest agent + ACPI dead | (above) | rules out "only `tailscaled` died" — the whole guest OS is wedged |
| Read the guest | `qm terminal 100` | serial console blank — no login, no echo, no panic trace |

**Diagnosis:** silent guest-internal hard freeze. From the hypervisor's view the QEMU process kept
running while the guest kernel was wedged, which is why `qm status` said `running`.

## 2 — Why the logs don't name a cause

- **Guest journal** (`journalctl -b -1`) ends abruptly at `01:41:13 UTC` mid-normal-operation, with
  **no** shutdown sequence — the signature of a freeze too hard for journald to write another line.
  A kernel-signature grep (`oom|hung task|soft lockup|BUG:|call trace|watchdog`) found only the
  benign boot-time `NMI watchdog: Enabled`. Nothing was logged at the freeze.
- **Host journal** at the freeze moment was clean: no `kvm` / `vfio` / `nvidia` / `oom` / VMID-100
  message in 03:30–03:50 CEST, and the SMART textfile collector completed successfully at 03:41.
  **Not KE-14** — the host disk / HBA layer threw nothing.
- The in-guest **NMI watchdog was enabled but caught nothing**: under KVM it relies on hardware PMU
  counters that are unreliably virtualized, so it is not a dependable lockup detector here.

### The clock caveat that nearly misread the timeline

The guest runs `Etc/UTC`; the host runs `Europe/Berlin` (CEST, +2h), both confirmed with
`timedatectl`. Read naively, the guest's last line (`01:41`) lands inside the host's overnight
power-off gap (host boot -1 ended `01:01:10 CEST`; boot 0 began `01:58:09 CEST`), which is
impossible — the guest cannot log while the host is off. Applying the +2h offset puts the freeze at
**`03:41 CEST`**, inside host boot 0. That also aligns with `tailscale`'s "last seen ~8h ago" and
with the `NodeDown` firing time. The host was up off-schedule because the admin had powered it on
manually for night work and gone to sleep before the freeze — **not** a `homelab_schedule` defect.

## 3 — Recovery

Graceful paths were already exhausted (QGA guest-ping and ACPI powerdown both timed out), so a hard
power-cycle:

```
qm stop 100    # QMP quit attempt, then the QEMU process is killed — the plug-pull equivalent
qm start 100   # fresh QEMU process; guest boots
```

The node returned to `active; direct` within ~2 min. The clean host disk layer (established above)
made the unclean-shutdown journal replay low-risk. `ssh gpu` succeeded again; all alerts resolved.

## 4 — Detection worked; response did not

The monitoring stack from the KE-8 remediation performed correctly:

| Time (CEST) | Alert | Note |
|---|---|---|
| 02:02 | `NodeDown` FIRING + immediately RESOLVED | boot transient as vm100 came up after the manual power-on |
| **03:45** | `NodeDown` + `ServiceDown` jellyfin + `ServiceDown` audiobookshelf | the freeze — ~4 min after 03:41, after >2 min of failed scrapes |
| 07:50 | same, re-notified | Alertmanager `repeat_interval` — still firing |
| 11:45 | all RESOLVED | after `qm stop`/`start` |

The alert reached Discord within minutes and stayed firing for ~8 h. The gap was **purely human**:
it fired at 03:45 while the admin slept, and there is no overnight escalation and no auto-recovery.

## System State After This Session

- vm100 up and healthy (`active; direct`, load ~0.04, memory ~4 %); all vm100 alerts resolved.
- No configuration was changed — this was a recovery, not a fix. The freeze cause remains open.

## Open Items

- **Auto-recovery (proportionate fix):** QEMU watchdog device (`i6300esb`) + `softdog` in the guest
  to reset a wedged guest automatically instead of an 8 h manual outage. Do not rely on the in-guest
  NMI watchdog (see above).
- **Survivable forensics:** `kdump` / `pstore` so the next freeze leaves a trace the live console
  and journal cannot provide.
- **Recurrence unquantified:** first recorded occurrence. If it repeats, open a real investigation;
  leading candidate is the KE-10 NVIDIA/CUDA path on this same node.
- **Doc reconciliation (separate):** `node-exporter-smarttext.service` runs on the Proxmox host,
  which contradicts the "SMART monitoring not deployed" note in `CLAUDE.md` and
  `docs/platform/operations.md` — verify whether it is wired to alerts and correct the docs.

## Configuration Changes Made

None. Recovery only (`qm stop 100` / `qm start 100`). No persistent change to vm100 or the host.

## Lessons Learned

- `qm status: running` is a hypervisor statement, not a guest-health statement. A guest can be
  hard-frozen while the VM reads `running`; QGA guest-ping and the serial console are the
  guest-health probes.
- When guest and host clocks differ, align timelines with the offset **before** reasoning about
  "impossible" gaps — a UTC-vs-CEST mismatch nearly placed the freeze in the host's power-off window.
- Absence of data is not absence of a problem: the empty host-journal window first looked like a
  logging gap and was really the host's scheduled-off period. `journalctl --list-boots` + `uptime`
  disambiguated it.
- Detection ≠ response. The stack alerted correctly; an 8 h outage still resulted because nothing
  escalated overnight and nothing auto-recovered. For a hobby node the fix is a watchdog, not a page.

## Related Documents

- [KE-17 — this incident's known-error entry](../known-errors.md#ke-17)
- [KE-10 — Jellyfin loses CUDA access (same node, NVIDIA path)](../known-errors.md#ke-10)
- [KE-14 — boot-SSD I/O errors (excluded here)](../known-errors.md#ke-14)
- [KE-8 — the observability model that caught this](../known-errors.md#ke-8)
- [VM100 node](../../nodes/vm100.md)
- [Proxmox Host](../proxmox-host.md)
- [Platform Changelog](../changelog.md)
