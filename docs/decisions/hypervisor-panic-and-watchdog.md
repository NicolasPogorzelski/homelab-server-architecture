# Hypervisor Panic Policy and the softdog Question

## Status

Decided 2026-09-11 for the panic policy. The watchdog half is decided against, with the condition
under which it would be revisited written down rather than left as a feeling.

## Context

On 2026-08-20 a kernel oops cascade left the Proxmox host alive and unreachable for roughly two
hours ([KE-21](../platform/known-errors.md#ke-21)). SSH completed its TCP handshake and never sent
a banner. The web interface served a login page and then refused its own tickets. Every guest read
`unknown`. The kernel had logged the fault at 12:39 and kept running, which is what Linux does
after an oops: it kills the thread that tripped it and continues, still holding whatever that
thread held.

That default is right on a machine somebody can reach. An operator with a console collects the
trace, unwedges what can be unwedged, and reboots on their own terms. This host cannot be reached.
The single GPU is passed through to vm100 with `x-vga=1`, there is no serial console, and the board
carries no separate management processor, so `getty@tty1` writes to a framebuffer a guest owns. The
recovery path on 2026-08-20 was a power button.

Three monitoring gaps came out of that incident. Two are closed: `FilesystemMountTimeout` reads the
`node_filesystem_device_error` series that had sat at 1 from the first minute, and
`SystemdUnitStuckActivating` reads the units that hang in `activating` and therefore never become
`failed`. The third is this document: nothing gave the machine a way out on its own.

## The two mechanisms, and why they are not the same

They get discussed together because both end in a reboot, but they answer different questions.

| | `panic_on_oops` | `softdog` |
|---|---|---|
| Trigger | The kernel detected a fault and said so | Nothing fed the watchdog in time |
| Requires | A kernel healthy enough to log | Nothing; it fires when the kernel is too wedged to act |
| Catches | Oops cascades, the 2026-08-20 shape | Total kernel lockup, including a silent one |
| Cost of a false positive | None: an oops is never normal | A reboot caused by load, not by fault |

`panic_on_oops` covers the incident that happened. `softdog` covers the incident that has not
happened here yet and would leave no trace when it did - which is the shape of
[KE-17](../platform/known-errors.md#ke-17) and [KE-20](../platform/known-errors.md#ke-20), both
guest freezes with no recorded cause.

## Decision 1: panic on oops, reboot after ten seconds

`kernel.panic_on_oops = 1` and `kernel.panic = 10`, owned by the `kernel_panic_policy` role.

The reasoning is short. Both outcomes take the guests down; only one of them comes back without
somebody walking to the machine. An oops is not a state this host recovers from usefully, because
the parts of it that matter - pmxcfs, pveproxy, the storage stack - are exactly the parts that hang
when a thread dies holding a lock.

Ten seconds rather than zero or one. Zero means "wait forever", which is the behaviour being
replaced. One second does not reliably let the `netconsole` receiver on this host take the frames
that explain the reboot, and a reboot nobody can explain trades one silent failure for another.

Scope is the hypervisor. The LXCs share this kernel and cannot set the value - a sysctl write in an
unprivileged container is refused. The two VMs run kernels of their own, and the argument plausibly
transfers, but the evidence does not: neither vm100 freeze produced an oops, so this setting would
not have caught either, and vm100 has no snapshot to fall back on. That is recorded as a proposal
in the [remediation plan](../platform/remediation-plan.md), not folded in here.

## Decision 2: softdog stays unarmed, and the condition is written down

`softdog` is loaded on this host and not armed. Arming it on Proxmox means enabling the HA stack,
because `watchdog-mux` is started by it, and that is the objection: the HA stack on a single node
with no quorum partner will fence the node it is supposed to protect. This platform is documented
as recovery-oriented and explicitly not highly available, and turning on half of a clustering
feature to obtain a reboot timer inverts that.

The honest counter-argument is that `panic_on_oops` only helps when the kernel is well enough to
notice, and a lockup is precisely when it is not. That is true, and it is the residual risk this
decision accepts.

Revisit when either of these becomes true:

- A lockup occurs on this host that leaves no oops in the journal and no `netconsole` frames, i.e.
  a failure `panic_on_oops` demonstrably could not catch. One occurrence is enough; this is not a
  frequency threshold.
- The hardware gains an out-of-band path - a board with a management processor, or onboard graphics
  usable while the GPU is passed through - at which point the whole argument changes, because
  "alive and unreachable" stops being equivalent to "down".

`nmi_watchdog`, which needs no HA stack, was considered as the middle option and rejected for this
purpose: it detects a CPU stuck in the kernel and its default action is to log, so on its own it
produces another record of a machine nobody can reach. It becomes interesting only in combination
with `panic_on_oops`, where a hard-lockup panic would inherit the reboot - worth measuring on this
hardware before relying on it, and not on the strength of a manual page.

## Consequences

- An oops on the hypervisor now costs a reboot and roughly the boot time of eleven guests, instead
  of an unbounded outage ending in a power cycle.
- The evidence for such a reboot lives in the persistent journal and in the `netconsole` receiver.
  If both are empty after an unexplained reboot, that is itself the finding: it means the machine
  did not panic, and something else restarted it.
- A reboot loop is possible in principle - a fault that reproduces on every boot would cycle the
  host. It would be visible immediately through `NodeDown` flapping and the guests never settling,
  and the exit is the same power button as before, so this trades an unbounded silent outage for a
  loud one.

## Verification

```bash
# On the Proxmox host, after applying the role:
sysctl -n kernel.panic_on_oops kernel.panic   # expect 1 and 10
systemctl status netconsole-receiver.service  # the channel that captures the trace
```

The role reads both values back from the running kernel and fails if a later file in
`/etc/sysctl.d/` overrides them, rather than reporting the write it just made.

## Related Documents

- [KE-21 - the oops cascade](../platform/known-errors.md#ke-21)
- [Proxmox host](../platform/proxmox-host.md)
- [Remediation plan](../platform/remediation-plan.md)
- [Hard shutdown recovery](../../runbooks/platform/hard-shutdown-recovery.md)
