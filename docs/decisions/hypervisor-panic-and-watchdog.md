# The Hypervisor Panics on Oops; softdog Stays Without a Client

## Status
Implemented 2026-09-11 (panic policy, `kernel_panic_policy` role). The watchdog half is decided
against, with a revisit condition below. Supersedes / superseded by: -.

## Context
On 2026-08-20 a kernel oops cascade left the Proxmox host alive and unreachable for about two hours
([KE-21](../platform/known-errors.md#ke-21)): SSH completed the TCP handshake and never sent a banner,
the web interface refused its own tickets, every guest read `unknown`. After an oops Linux kills
the faulting thread and continues, still holding whatever that thread held.

That default suits a machine with a console. This host has none: the single GPU is passed through
to vm100 with `x-vga=1`, there is no serial console and no management processor, so `getty@tty1`
writes to a framebuffer a guest owns. Recovery on 2026-08-20 was the power button.

Two monitoring gaps from that incident are closed (`FilesystemMountTimeout`,
`SystemdUnitStuckActivating`). The third was that nothing gave the machine a way out on its own.

| | `panic_on_oops` | `softdog` |
|---|---|---|
| Trigger | The kernel detected a fault and logged it | Nothing fed the watchdog in time |
| Requires | A kernel healthy enough to log | Nothing; fires when the kernel is too wedged to act |
| Catches | Oops cascades, the 2026-08-20 shape | Total lockup, including a silent one |
| Cost of a false positive | None: an oops is never normal | A reboot caused by load, not by fault |

`softdog` would cover the silent shape of [KE-17](../platform/known-errors.md#ke-17) and
[KE-20](../platform/known-errors.md#ke-20), both guest freezes with no recorded cause.

## Options
- **Keep the default (no panic on oops).** Lost: an oops leaves pmxcfs, pveproxy and the storage
  stack hanging on held locks, with no way back except physical access.
- **Arm softdog through the HA stack.** Lost: HA on a single node with no quorum partner fences the
  node it should protect, and the platform is recovery-oriented, not highly available.
- **`nmi_watchdog` alone.** Lost: its default action is to log, which produces another record on a
  machine nobody can reach. Combined with `panic_on_oops` a hard-lockup panic might inherit the
  reboot; that needs measuring on this hardware first.
- **Panic on oops, reboot after ten seconds; softdog without a client.** Chosen.

## Decision
`kernel.panic_on_oops = 1` and `kernel.panic = 10` on the hypervisor, owned by `kernel_panic_policy`.
Both outcomes take the guests down; only the reboot brings them back without someone at the machine.
Ten seconds, not zero (wait forever) or one (too short for the `netconsole` receiver to take the
frames that explain the reboot).

Scope is the hypervisor. LXCs share its kernel and cannot set the value. The VMs run their own
kernels; neither vm100 freeze produced an oops, so the setting would not have caught either. vm100
can be snapshotted since 2026-10-10; extending the policy to the VMs is a proposal in the
[remediation plan](../platform/remediation-plan.md).

No HA resource is configured. The softdog device is nevertheless open, measured 2026-09-16:

```
/sys/class/watchdog/watchdog0/identity : Software Watchdog
                                 state : active
                               timeout : 10
/dev/watchdog                          : held by watchdog-mux, pid 1439
```

`watchdog-mux.service` is wanted by `pve-ha-lrm` and `pve-ha-crm`, which run on a stock install.
`ha-manager config` is empty and the local resource manager sits at `wait_for_agent_lock`, so no
client ever stops feeding the timer. The kernel logs `softdog: ... (nowayout=0)` at load and
`CONFIG_WATCHDOG_NOWAYOUT` is unset: if `watchdog-mux` dies, its descriptor closes and the timer
stops, so losing the process costs the watchdog, not the host.

Revisit softdog when either becomes true:

- a lockup on this host leaves no oops in the journal and no `netconsole` frames - one occurrence
  is enough;
- the hardware gains an out-of-band path (management processor, or usable onboard graphics while
  the GPU is passed through).

## Consequences
- An oops costs a reboot and the boot time of the 9 guests instead of an unbounded outage ending in
  a power cycle.
- The evidence for such a reboot is in the persistent journal and the `netconsole` receiver. If
  both are empty after an unexplained reboot, the machine did not panic; something else restarted
  it.
- A fault that reproduces on every boot would loop the host. `NodeDown` flapping makes it loud, and
  the exit is the same power button as before.
- A total lockup without an oops remains uncovered; that residual risk is accepted.

## Verification
```bash
# On the Proxmox host:
sysctl -n kernel.panic_on_oops kernel.panic   # expect 1 and 10
systemctl status netconsole-receiver.service  # the channel that captures the trace
```

The role reads both values back from the running kernel and fails if a later file in
`/etc/sysctl.d/` overrides them.

## Related Documents
- [KE-21 - the oops cascade](../platform/known-errors.md#ke-21)
- [Proxmox host](../platform/proxmox-host.md)
- [Hard shutdown recovery](../../runbooks/platform/hard-shutdown-recovery.md)
