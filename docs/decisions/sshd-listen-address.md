# sshd Binding: One Decision for Ten Nodes, Not an Exception for One

## Status

Decided 2026-09-11. The mechanism is built and defaulted off; the rollout is a supervised window
per node, not a sweep.

## Context

The platform binding rule says a service binds its Tailscale address, or loopback behind
`tailscale serve`, and never a LAN interface. `CLAUDE.md` and `vm100.md` both recorded sshd on
vm100 as the exception to that rule.

The 2026-08-17 sweep measured it and the sentence was the wrong way round. sshd binds `*:22` on
lxc200, lxc210, lxc211, lxc220, lxc230, lxc260, on vm100, on vm102 and on the Proxmox host. Only
lxc250 pins `ListenAddress`. Ten of eleven nodes violate the rule; one follows it.

That changes what kind of decision this is. A single node deviating is a node-level fix. A rule
that the fleet does not follow is either a rule nobody decided to enforce or a rule that is wrong,
and writing "vm100 is the exception" in two documents for months is what kept anyone from asking
which.

The acute risk is closed and has been since 2026-07-09: password authentication is off everywhere,
and `ssh_hardening` keeps it off. What remains is a correctness and honesty problem - a documented
rule that the estate does not implement - plus real exposure that is easy to understate. These are
dual-stack hosts with a routable IPv6 address on the LAN interface, so `*:22` is not only the local
segment.

## What makes this harder than it looks

Pinning `ListenAddress` to a Tailscale address couples sshd's start to `tailscaled` having
connected. That is the [KE-18](../platform/known-errors.md#ke-18) class, and this fleet has
already produced five separate instances of it. sshd's version of it is the worst-behaved:

- sshd exits 255 when it cannot bind.
- Debian's `ssh.service` sets `RestartPreventExitStatus=255`, so the packaged unit will not restart
  it on exactly that failure.
- A node whose sshd does not come back is reachable only by `pct exec` from the hypervisor, or by
  console on the two VMs, or not at all on the hypervisor itself.

lxc250 survives this because its hand-written drop-in cleared that exit-status list, which is a
detail that was nearly lost when the drop-in was adopted into a role. The `tailscale_boot_gate`
role carries it as `tailscale_boot_gate_clear_restart_prevent`, off by default, and this is the
case it exists for.

## Options

**Leave it.** Zero risk, and the rule stays false. Rejected: the estate documents a control it does
not implement, and the next audit finds the same thing again.

**Bind loopback and reach sshd through `tailscale serve`.** Serve proxies TCP, so it is possible,
but it puts the administrative path through a userspace daemon that is also the thing most likely
to be broken when the administrative path is needed. Rejected on that alone.

**Delete the rule for sshd and say so.** Honest, cheap, and it accepts an SSH daemon on a routable
IPv6 address. Rejected, but it is the option that makes the next one worth the risk rather than
merely tidy.

**Pin `ListenAddress` to the Tailscale address, behind the boot gate, one node at a time.**
Chosen.

## Decision

`ssh_hardening` gains `ssh_hardening_listen_address`, unset by default. Where it is set, the role
writes a single `ListenAddress` and refuses to proceed unless the node also declares `ssh.service`
in `tailscale_boot_gate_units` with `tailscale_boot_gate_clear_restart_prevent: true`. The refusal
is the point: the two settings are only safe together, and a role that let one be configured
without the other would produce precisely the failure this fleet has recorded five times.

Rollout order, and it is deliberately the reverse of the order anyone would guess:

1. **The seven LXCs**, because `pct exec` from the hypervisor recovers any of them without SSH.
2. **vm102**, which has a Proxmox console.
3. **vm100**, which has a console but no snapshot to roll back to, and is therefore worth doing
   late and alone.
4. **The Proxmox host, last or never.** It has no out-of-band console: the GPU is passed through
   with `x-vga=1` and `getty@tty1` writes to a framebuffer a guest owns. Locking sshd out there
   means physical access with the passthrough removed from vm100's configuration first. Whether
   that node is worth the risk at all is a separate decision, and the honest answer today is that
   it is not: it is the one node where the recovery cost exceeds the exposure it would close.

Each step is one node, in a session with a second terminal already connected to that node, and the
existing session is not closed until a new one has been opened.

## What this does not cover

Apache on lxc210 binds `*:80` and `*:443` and is not part of this. Its plausible fix is moving
Nextcloud behind `tailscale serve`, which would also retire
[KE-16](../platform/known-errors.md#ke-16) - the on-disk certificate that gets renewed while Apache
keeps serving the old one from memory. That is a project with its own rollback question, not a
`ListenAddress` line, and folding it in here would make a reviewable change unreviewable.

The wider point that came out of the same audit belongs here rather than there: nothing enforces
the untrusted-LAN declaration at the host boundary on any node. The Tailscale ACL governs the
overlay, `pve-firewall` is off, and the only host-level filter on the fleet is the nftables table
on vm102. Every wildcard bind is reachable because no filter says otherwise. Pinning
`ListenAddress` closes one of them properly; the others are closed by the `nft_guard` role where
the service cannot bind correctly itself. See
[`physical-controls.md`](../platform/physical-controls.md) for the posture statement.

## Consequences

- A node whose Tailscale identity is revoked or whose `tailscaled` will not start is reachable only
  by `pct exec` or console. That is the trade being made, and it is the same trade lxc250 has lived
  with since it was built - documented in `CLAUDE.md` as "SSH unreachable for 30 to 60 seconds
  after boot, intentional hardening, not a bug".
- `fleet_snapshot` already records listening sockets per node, so the rollout is measurable from
  the weekly snapshot rather than from a claim in this document.
- `CLAUDE.md` and `vm100.md` both need their "vm100 is the exception" wording corrected, because it
  is the sentence that hid this for months.

## Verification

Per node, after the change and after a reboot:

```bash
ss -tlnp 'sport = :22'                       # one line, the Tailscale address, no wildcard
systemctl show ssh.service -p NRestarts       # expect 0 across the boot
journalctl -u ssh.service -b 0 | grep -i bind
```

`NRestarts=0` alone proves nothing on a node that has not rebooted. Read it together with
`systemctl show ssh.service -p ActiveEnterTimestamp` against `uptime -s`, which is the proof
[KE-18](../platform/known-errors.md#ke-18) settled on after the same mistake.

## Related Documents

- [KE-18 - ordering is not readiness](../platform/known-errors.md#ke-18)
- [KE-24 - sshd's reload is a re-exec](../platform/known-errors.md#ke-24)
- [Loopback + Tailscale Serve](loopback-tailscale-serve.md)
- [Tailscale ACL](../platform/tailscale-acl.md)
- [Remediation plan](../platform/remediation-plan.md)
