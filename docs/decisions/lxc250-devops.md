# One Control Node for All Changes (lxc250)

## Status
Implemented 2026-03-04. Tag changed to `tag:control` on 2026-09-26. Supersedes / superseded by: -.

## Context
Code and infrastructure changes were made from several admin machines, which caused synchronization
overhead and diverging Git state. A single management node removes that: all changes are made in
one place, every other node only receives them.

## Options
- **A VM.** Lost: no hardware passthrough, no Docker and no custom kernel needed; QEMU and a second
  kernel would consume part of a 2 GB budget that an LXC uses almost entirely for the workload.
- **Ubuntu Server.** Lost: slightly larger, and no advantage for this workload; Debian matches the
  other LXCs.
- **Keep working from the admin workstations.** Lost: the synchronization problem above.
- **A dedicated unprivileged Debian LXC.** Chosen.

## Decision
CTID 250 is the control node. Git operations, code editing, Ansible runs and IaC work happen on it
only. It holds the Ansible key, the vault password and root access to the hypervisor through
Ansible.

| Property | Value |
|---|---|
| CTID | 250 |
| Hostname | devops |
| OS | Debian 12 (bookworm) |
| Resources | 2 cores, 2048 MB RAM, 512 MB swap, 8 GB disk on local-lvm |
| Unprivileged | yes, nesting enabled (required for Tailscale) |
| Tailscale tag | `tag:control` |
| Onboot | yes |

CTID ranges: 100-109 hardware-proximate VMs, 200-209 monitoring, 210-219 cloud, 220-229 media,
230-239 AI stack, 250-259 DevOps and management tooling, 260-269 database and platform services.

**Tag.** lxc250 carries its own `tag:control`, not `tag:admin`. It is an automation identity with
one job: SSH to every node and the Prometheus API for the drift sweep. Admin workstations reach it on
22 only. The grants are owned by [tailscale-acl.md](../platform/tailscale-acl.md); lxc250 advertises
its tag itself, so a re-registration asks for the same one.

**Access.** SSH with ED25519 keys from admin devices. Password authentication is off, as on every
node (`ssh_hardening`). sshd binds the Tailscale address only
([sshd decision](sshd-listen-address.md)); the fallback when the tailnet is down is `pct exec 250`
on the hypervisor.

## Consequences
- Single point of failure for Git and IaC operations; accepted for a single-administrator platform.
  Its credentials are escrowed off-site ([remediation plan](../platform/remediation-plan.md)).
- No ad-hoc changes from other machines.
- 2 GB RAM limits concurrent heavy workloads; enough for Git, Ansible and editing.
- Until 2026-09-26 lxc250 shared `tag:admin` with the workstations and `tag:admin:*` connected them
  on every port; the separate tag removed that path in both directions.

## Related Documents
- [Tailscale ACL Model](../platform/tailscale-acl.md)
- [Node Documentation: LXC250](../nodes/lxc250.md)
- [Architecture Overview](../architecture/overview.md)
