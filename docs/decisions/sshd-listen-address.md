# sshd Binds the Tailscale Address on Every Guest

## Status
Implemented 2026-10-13: pinned on all 9 guests; the hypervisor is deliberately unpinned. Decided
2026-09-11. Supersedes / superseded by: -.

Verified 2026-10-12 (lxc250: 2026-10-13): on every guest `ss` shows the Tailscale address alone on
port 22 and `NRestarts=0`; the containers and vm100 after a reboot, vm102 after a reload (its first
cold boot with the pin is still to come).

## Context
The platform binding rule says a service binds its Tailscale address, or loopback behind
`tailscale serve`, and never a LAN interface. The 2026-08-17 sweep found sshd on `*:22` on every
node except lxc250. The nodes are dual-stack with a routable IPv6 address on the LAN interface, so
`*:22` is not limited to the local segment. Password authentication is off everywhere
(`ssh_hardening`), so the exposure is a key-only daemon on an address the rule says it must not use.

Two mechanisms make the pin harder than one `ListenAddress` line:

- **Boot readiness.** Binding the Tailscale address couples sshd's start to `tailscaled` having
  connected ([KE-18](../platform/known-errors.md#ke-18)). sshd exits 255 when it cannot bind, and
  Debian's `ssh.service` sets `RestartPreventExitStatus=255`, so the packaged unit never retries.
- **Socket activation.** Measured 2026-09-17: `ssh.socket` was enabled on lxc200, lxc210, lxc211,
  lxc220, lxc230 and lxc260. There systemd holds `*:22` and hands sshd a connected descriptor, so
  `ListenAddress` is inert; applied to lxc220 it changed the file and not the bind
  ([KE-24](../platform/known-errors.md#ke-24)).

## Options
- **Leave the wildcard bind.** Lost: the platform would document a control it does not implement.
- **Bind loopback and reach sshd through `tailscale serve`.** Lost: puts the administrative path
  through the daemon most likely to be broken when that path is needed.
- **Drop the rule for sshd.** Lost: accepts an SSH daemon on a routable IPv6 address.
- **Pin `ssh.socket` to the Tailscale address.** Lost: keeps Debian's service model, but moves the
  readiness gate to a socket unit and gives two service models across the fleet.
- **Turn socket activation off and pin `ListenAddress`, behind the boot gate, one node at a time.**
  Chosen.

## Decision
`ssh_hardening_listen_address` is set per node in `host_vars` on all 9 guests. Where it is set,
`ssh_hardening`:

1. refuses to run unless the node declares `ssh.service` in `tailscale_boot_gate_units` with
   `tailscale_boot_gate_clear_restart_prevent: true` - the two settings are only safe together;
2. stops and disables `ssh.socket` and restarts `ssh.service`, so sshd owns its socket;
3. flushes handlers, so the reload carrying the new `ListenAddress` runs before the check;
4. fails the run unless `ss` shows the Tailscale address alone on 22.

The variable is empty by default and never derived from `ansible_host`, so a merge cannot pin a node
unsupervised. Each node was changed in a window with a second terminal open: the containers first
(`pct exec` recovers them), then vm100 behind a snapshot, then vm102.

The Proxmox host stays on the wildcard bind. It has no out-of-band console (the GPU is passed
through to vm100 with `x-vga=1`), so its LAN path from the two admin workstations is the only way in
when Tailscale does not come up; `lan_guard` admits exactly those two senders on 22. A pin on the
Tailscale address would remove that path. A pin on the Tailscale and LAN addresses together would
cut only loopback, the Tailscale IPv6 address and link-local, because the host has no global IPv6
address (measured 2026-10-13). Revisit if the host gains an out-of-band console (IPMI, KVM over IP,
or a display output of its own).

## Consequences
- A guest whose `tailscaled` does not start or whose identity is revoked is reachable only by
  `pct exec` (containers) or the Proxmox console (VMs). sshd is unreachable for up to the boot gate's
  timeout after a boot; that is intended.
- On every guest `lan_guard` already drops new inbound LAN connections on 22, so the pin is the
  second layer, not the only one.
- Re-enabling socket activation is `systemctl enable --now ssh.socket` through `pct exec` or the
  console, after removing the variable from `host_vars`.
- `fleet_snapshot` records listening sockets per node, so a regression shows in the weekly snapshot.
- Apache on lxc210 binds `*:80` and `*:443` and is outside this decision. Moving Nextcloud behind
  `tailscale serve` would also retire [KE-16](../platform/known-errors.md#ke-16), and is its own
  change with its own rollback.

## Verification
Per node, after the change and after a reboot:

```bash
ss -tlnp 'sport = :22'                       # one line, the Tailscale address, no wildcard
systemctl show ssh.service -p NRestarts       # expect 0 across the boot
journalctl -u ssh.service -b 0 | grep -i bind
```

`NRestarts=0` proves nothing on a node that has not rebooted. Read it together with
`systemctl show ssh.service -p ActiveEnterTimestamp` against `uptime -s`
([KE-18](../platform/known-errors.md#ke-18)).

## Related Documents
- [KE-18 - ordering is not readiness](../platform/known-errors.md#ke-18)
- [KE-24 - sshd's reload is a re-exec](../platform/known-errors.md#ke-24)
- [Loopback + Tailscale Serve](loopback-tailscale-serve.md)
- [Tailscale ACL](../platform/tailscale-acl.md)
