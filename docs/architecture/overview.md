# Architecture Overview

One Proxmox host runs nine guests, separated by responsibility: compute, storage, and one service
per container. The host and all nine guests are Ansible-managed from lxc250. The document index is
in the [README](../../README.md#documentation).

## Components

### Hypervisor (Proxmox VE)

- Runs the VMs and unprivileged LXCs, Ansible group `proxmox`
- Single host, no cluster, no failover; recovery is procedural
  ([platform restore](../../runbooks/platform/platform-restore.md))
- Powers down nightly and wakes on schedule (`homelab_schedule`); every scheduled job is a systemd
  timer with `Persistent=true`

### VMs

- vm100 - GPU compute (Ubuntu, Docker, NVIDIA passthrough): Jellyfin, Audiobookshelf, `llama-server`
- vm102 - storage (Debian): SnapRAID, MergerFS, Samba

### LXCs

- lxc200 - monitoring: Prometheus, Grafana, Alertmanager
- lxc210 - Nextcloud: Apache, PHP, MariaDB, Redis
- lxc211 - Paperless-ngx (Docker)
- lxc220 - Calibre-Web (Docker)
- lxc230 - OpenWebUI (Docker)
- lxc250 - Ansible control node
- lxc260 - PostgreSQL platform database

Each node has its own document under [`docs/nodes/`](../nodes/).

## Design Principles

- Separation of compute, storage and services
- Zero-trust access: the Tailscale overlay and its ACL are the only remote path
- Least privilege: read-only media consumers, one SMB identity per service
- Reboot safety: units that need a Tailscale address wait for it, network mounts are automounts

Two qualifications:

- "No public exposure" holds at the network boundary, not at every socket. A few services bind
  wildcard addresses; the router's missing forwarding rules keep the internet out and, since
  2026-10-01, `lan_guard` on every node keeps the LAN out. The measured list is in the
  [exposure model](exposure-diagram.md).
- Reboot safety is enforced where the faults were found: units ordered after `tailscaled` without
  waiting for an address ([KE-18](../platform/known-errors.md#ke-18)) and fstab mounts of shares
  served by a guest not yet started ([KE-15](../platform/known-errors.md#ke-15)).

## Networking Layer

- Identity-based overlay (Tailscale), one tag per server
- Grants name a port, and a host where a tag holds several services
- The policy lives in the Tailscale admin console, which is the source of truth;
  [tailscale-acl.md](../platform/tailscale-acl.md) mirrors it and is applied by hand
- No service is published to the LAN or the internet

## The Four Views

| View | Answers |
|---|---|
| [Logical architecture](diagram.md) | Who may reach what, where the bytes live, what is monitored |
| [Failure domains](failure-domains.md) | What dies with which disk |
| [Backup and recovery](backup-flow.md) | What is copied, and what is not |
| [Exposure model](exposure-diagram.md) | What is reachable from where |

## Where to Go Next

- Why the trade-offs went the way they did: [design decisions](../decisions/design-decisions.md)
- Open work, ranked by loss risk: [remediation plan](../platform/remediation-plan.md)
