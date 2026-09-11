# MagicDNS on the Debian Containers: Take resolved Out of the Path

## Status

Decided 2026-09-11 for lxc250, where the fault was found. Applied to that node first and to the
rest only after a boot proves it there, because the same configuration is on every Debian container
here and a name-resolution change that goes wrong goes wrong everywhere at once.

## Context

Found 2026-09-08: anything on lxc250 that addresses a node by its `.ts.net` name fails to resolve.
The control node is the one place where tooling addresses nodes by name rather than by inventory
variable, so this was found by `fleet-drift.sh` failing rather than by a person noticing.

The ACL is not the cause, and ruling that out first was worth the minute it took: the node holds
`tag:admin` and reaches every port.

The mechanism, measured:

- `systemd-resolved` is active.
- `/etc/nsswitch.conf` has `hosts: files resolve [!UNAVAIL=return] dns`.
- `resolved` knows nothing about the Tailscale resolver - it was never told.
- `[!UNAVAIL=return]` ends the lookup as soon as `resolve` answers at all. `resolve` is available,
  it simply does not know the name, so it returns NXDOMAIN and the `dns` source after it is never
  consulted.
- `/etc/resolv.conf`, which `dns` would have read, is correct. `tailscaled` wrote it with the right
  nameserver and the right search domain.
- A direct UDP query to the MagicDNS resolver answers immediately.

So two resolvers are present, one of them knows the answer, and the lookup never reaches it. The
file that would have worked was correct the whole time, which is the detail worth keeping: nothing
was misconfigured in the sense anybody would grep for.

`fleet-drift.sh` works around it with `curl --resolve`, which keeps SNI and certificate
verification intact rather than disabling them. That is a workaround in the right place and it
stays.

## Options

**Point resolved at the Tailscale resolver.** A drop-in giving `resolved` the MagicDNS address for
the `.ts.net` domain. Correct in principle, and it is what Tailscale does by itself on a host where
it detects `resolved` through D-Bus. Rejected here: it adds a second place where the tailnet's
resolver address is written down, and that address is exactly the kind of thing that changes
without anybody editing a drop-in. The failure mode is a container that resolves names right up
until it silently does not.

**Let tailscaled drive resolved.** The supported path, and the reason it is not already happening
is not established - `tailscaled` wrote `/etc/resolv.conf` directly instead, which is its fallback
when it cannot use the `resolved` D-Bus interface. Finding out why would be the most correct fix
and is the one that depends on something not yet measured. Worth doing; not worth blocking on.

**Take `resolve` out of `nsswitch.conf`.** One line, container-local, no daemon configuration, and
it makes glibc read the `/etc/resolv.conf` that is already correct. Chosen.

**Remove `systemd-resolved` entirely.** Cleaner in the sense that a dead mechanism is better than a
bypassed one, and it is the option to revisit. Not chosen now because removing the package changes
who owns `/etc/resolv.conf`, and doing that in the same change as the fix would make a failure
ambiguous between two causes.

## Decision

On lxc250, `hosts:` in `/etc/nsswitch.conf` becomes `files dns`, and `systemd-resolved` is left
running but out of the resolution path.

The reasoning in one line: the correct answer is already in `/etc/resolv.conf`, so the smallest
honest fix is to stop short-circuiting the lookup before it gets there.

What makes this safe to do first on the control node rather than last: lxc250 is reachable by
`pct exec` from the hypervisor without any name resolution at all, and its own Ansible runs address
nodes by the IP addresses in `hosts.yml`. A broken resolver there cannot lock anybody out.

## Rollout

1. lxc250, by hand, then a reboot to prove it survives one.
2. Read the same three facts back on the other six containers before touching them - `nsswitch.conf`
   ordering, whether `resolved` is active, and whether `/etc/resolv.conf` carries the MagicDNS
   nameserver. The assumption that they are identical is exactly the assumption
   [KE-23](../platform/known-errors.md#ke-23) punished.
3. Only then a role, if the answer is the same on all of them. A single-node fix does not need one.

## Consequences

- Name resolution on the changed node no longer benefits from `resolved`'s cache or its per-link
  configuration. Neither is in use here.
- `resolved` keeps running and keeps listening on 127.0.0.53. That is untidy and deliberate: the
  point of this change is to alter one thing.
- If `tailscaled` ever stops writing `/etc/resolv.conf`, resolution breaks completely rather than
  partially. That is a louder failure than the current one, which is an improvement - the present
  fault has been silent since the container was built.

## Verification

```bash
getent hosts <node>.<tailnet>.ts.net     # must return the 100.x address
grep '^hosts:' /etc/nsswitch.conf        # files dns
resolvectl status | head -20             # resolved still running, no longer consulted
```

After a reboot, repeat the first command before concluding anything: the file `tailscaled` writes
is recreated at every start, and this whole entry exists because a correct file was not being read.

## Related Documents

- [KE-23 - a role gained a task and seven nodes never received it](../platform/known-errors.md#ke-23)
- [Tailscale ACL](../platform/tailscale-acl.md)
- [LXC250 DevOps Workstation](lxc250-devops.md)
- [Ansible platform doc](../platform/ansible.md)
