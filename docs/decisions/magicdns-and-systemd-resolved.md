# MagicDNS on lxc250: systemd-resolved Leaves the Lookup Path

## Status
Implemented 2026-09-17 on lxc250, the only node it applies to. Decided 2026-09-11. Supersedes /
superseded by: -.

The `nsswitch` role is applied: on 2026-09-15 it set lxc250's `hosts:` line, and on 2026-09-17 it
stopped and disabled `systemd-resolved` there (`ansible/inventory/host_vars/lxc250.yml`). The
playbook `ansible/playbooks/nsswitch.yml` runs against all guests and is a no-op where
`nsswitch_hosts` is unset; it is in the weekly drift sweep (`ansible/drift-sweep.conf`), so a changed
line on any guest is reported.

Verified 2026-09-15: `hosts:` reads `files myhostname dns`, and `getent` resolves a short and a fully
qualified MagicDNS name on lxc250.

## Context
Found 2026-09-08: on lxc250 every lookup of a node's `.ts.net` name failed, so tooling on the
control node that addresses nodes by name broke (`fleet-drift.sh` was the first to fail). The ACL
was ruled out first. The mechanism, measured:

- `systemd-resolved` was active, and `/etc/nsswitch.conf` read
  `hosts: files myhostname resolve [!UNAVAIL=return] dns`.
- `resolved` had never been given the Tailscale resolver.
- `[!UNAVAIL=return]` ends the lookup whenever `resolve` answers at all. `resolved` was available,
  did not know the name and returned NXDOMAIN, so the `dns` source was never consulted.
- `/etc/resolv.conf`, which `dns` reads, was correct: `tailscaled` had written the MagicDNS
  nameserver and search domain into it. A direct UDP query to that resolver answered at once.

Measured 2026-09-12 on all seven containers: lxc250 alone carried `resolve` in `hosts:` and ran
`systemd-resolved`. lxc200, lxc210, lxc211, lxc220, lxc230 and lxc260 read `files dns` with
`resolved` inactive and resolve both short and fully qualified names. The fault is one node, not a
fleet-wide setting.

## Options
- **Give `resolved` the MagicDNS resolver in a drop-in.** Lost: a second place that records the
  tailnet's resolver address, which can change without anyone editing the drop-in.
- **Let `tailscaled` drive `resolved` over D-Bus.** The supported path; why `tailscaled` fell back
  to writing `/etc/resolv.conf` directly was never established. Not pursued.
- **Leave `resolved` running, remove `resolve` from `nsswitch.conf`.** One line, and glibc reads the
  `/etc/resolv.conf` that is already correct. Chosen first.
- **Also stop `resolved`.** Added on 2026-09-17: out of the lookup path, it only served
  unauthenticated LLMNR and mDNS on `0.0.0.0:5355` on the LAN, which the binding rule forbids. The
  package stays installed.

## Decision
On lxc250 `hosts:` is `files myhostname dns`, and `systemd-resolved` is stopped and disabled.
`myhostname` stays because it resolves the node's own name without a lookup. The `nsswitch` role
owns both settings; it refuses to stop `resolved` while `/etc/resolv.conf` still names the
`127.0.0.53` stub, fails if anything still listens on 5355, and resolves the node's own MagicDNS name
through `getent` after every change.

lxc250 was a safe first node: it is reachable through `pct exec` from the hypervisor without name
resolution, and its Ansible runs address nodes by the IP addresses in the inventory.

## Consequences
- lxc250 loses `resolved`'s cache and per-link configuration; neither was in use.
- If `tailscaled` stops writing `/etc/resolv.conf`, resolution on lxc250 fails completely rather
  than for MagicDNS names only, which is the louder failure.
- `fleet-drift.sh` keeps its `curl --resolve` workaround, which preserves SNI and certificate
  verification and does not depend on this fix.
- A new container from a template that ships `resolved` would repeat the fault, and the drift sweep
  would not report it: the role checks only nodes that declare `nsswitch_hosts`.

## Verification
```bash
getent hosts <node>.<tailnet-id>.ts.net   # returns the node's Tailscale address
grep '^hosts:' /etc/nsswitch.conf          # files myhostname dns
systemctl is-enabled systemd-resolved      # disabled
ss -tulnH | grep ':5355'                   # prints nothing
```

Repeat the first command after a reboot: `tailscaled` rewrites `/etc/resolv.conf` at every start.

## Related Documents
- [KE-23 - a role change that never reached seven nodes](../platform/known-errors.md#ke-23)
- [Tailscale ACL](../platform/tailscale-acl.md)
- [lxc250 DevOps workstation](lxc250-devops.md)
- [Ansible](../platform/ansible.md)
