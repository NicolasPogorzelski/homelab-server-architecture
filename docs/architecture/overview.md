# Architecture Overview

The infrastructure is modular and responsibility-driven. It is designed around clear separation of
concerns (compute vs. storage vs. services) and reboot-safe operation.

This page describes the shape of the platform. It does not repeat the document index - the
[README](../../README.md) carries that, and a second copy is the one that goes stale.

## Components

### Hypervisor (Proxmox VE)

- Hosts VMs and unprivileged LXCs
- Startup order modeled to ensure dependencies are met during reboot
- Single host, no cluster, no failover: recovery here is procedural, and the procedures are written

### VMs

- VM100 - Compute / GPU (Ubuntu, Docker, NVIDIA passthrough, media services)
- VM102 - Storage (Debian, MergerFS + SnapRAID + Samba)

### Service LXCs

- LXC200 - Monitoring (Prometheus + Grafana + Node Exporter)
- LXC210 - Nextcloud (classic stack: Apache + PHP + MariaDB + Redis)
- LXC211 - Paperless-ngx (document management, Docker in LXC)
- LXC220 - Calibre-Web (Docker in LXC)
- LXC230 - OpenWebUI (AI stack entrypoint, Docker in LXC)
- LXC240 - Vaultwarden (Docker in LXC, secrets tier)
- LXC250 - DevOps (central management workstation; Git, Ansible, IaC)
- LXC260 - PostgreSQL (centralized platform database)

## Design Principles

- Separation of concerns (compute, storage, services)
- Minimal coupling between components
- Zero-Trust access model (access enforced via Tailscale overlay + ACL policy-as-code)
- Least privilege access (RO/RW separation where applicable)
- Reboot-safe operation (mount and startup dependency modeling)

Two of these carry a qualification that belongs next to them rather than in a document a reader
might not reach.

**No public exposure** is true at the network boundary and not at the socket. Several services bind
wildcard addresses on nodes that carry a routable IPv6, so what prevents reachability from outside
is the absence of a forwarding rule on the router. The measured list is in
[the exposure model](exposure-diagram.md).

**Reboot-safe** is the design intent and was not the behaviour. Ordering a unit after `tailscaled`
does not wait for an address, which produced the same fault four times
([KE-18](../platform/known-errors.md#ke-18)); a plain fstab entry for a share served by a guest the
host has not started yet is attempted once and never retried
([KE-15](../platform/known-errors.md#ke-15)). Both classes are fixed where they were found, and
KE-18 still has one open instance.

## Networking Layer

- Zero-trust inspired access model
- Identity-based overlay networking (Tailscale)
- Explicit ACL segmentation between tiers
- No public service exposure, with the qualification above

## The four views

Start here rather than at a node document if you want to understand the platform as a whole.

| View | Answers |
|---|---|
| [Logical architecture](diagram.md) | Who may reach what, where the bytes live, what is monitored |
| [Failure domains](failure-domains.md) | What dies with which disk |
| [Backup and recovery](backup-flow.md) | What is copied, and what is not |
| [Exposure model](exposure-diagram.md) | What is reachable from where |

## Where to go next

- Nodes, services, platform documents, runbooks and decision records: the [README index](../../README.md#documentation)
- Why the trade-offs went the way they did: [Design Decisions](../decisions/design-decisions.md)
- What is currently open, ranked by what its loss would cost: [Remediation Plan](../platform/remediation-plan.md)
