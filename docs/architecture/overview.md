# Architecture Overview

The infrastructure is modular and responsibility-driven. It is designed around clear separation of concerns (compute vs. storage vs. services) and reboot-safe operation.

## Components

### Hypervisor (Proxmox VE)

- Hosts VMs and unprivileged LXCs
- Startup order modeled to ensure dependencies are met during reboot

### VMs

- VM100 – Compute / GPU (Ubuntu, Docker, NVIDIA passthrough, media services)
- VM102 – Storage (Debian, MergerFS + SnapRAID + Samba)

### Service LXCs

- LXC200 – Monitoring (Prometheus + Grafana + Node Exporter)
- LXC210 – Nextcloud (classic stack: Apache + PHP + MariaDB + Redis)
- LXC211 – Paperless-ngx (document management, Docker in LXC)
- LXC220 – Calibre-Web (Docker in LXC)
- LXC230 – OpenWebUI (AI stack entrypoint, Docker in LXC)
- LXC240 – Vaultwarden (Docker in LXC, secrets tier)
- LXC250 – DevOps (central management workstation; Git, Ansible, IaC)
- LXC260 – PostgreSQL (centralized platform database)

## Design Principles

- Separation of concerns (compute, storage, services)
- Minimal coupling between components
- Zero-Trust access model (no public exposure; access enforced via Tailscale overlay + ACL policy-as-code)
- Least privilege access (RO/RW separation where applicable)
- Reboot-safe operation (mount and startup dependency modeling)

## Networking Layer

- Zero-trust inspired access model
- Identity-based overlay networking (Tailscale)
- Explicit ACL segmentation between tiers
- No public service exposure

## Nodes

- [VM100 – GPU / Compute](../nodes/vm100.md)
- [VM102 – Storage](../nodes/vm102.md)
- [LXC200 – Monitoring](../nodes/lxc200.md)
- [LXC210 – Nextcloud](../nodes/lxc210.md)
- [LXC211 – Paperless-ngx](../nodes/lxc211.md)
- [LXC220 – Calibre-Web](../nodes/lxc220.md)
- [LXC230 – OpenWebUI](../nodes/lxc230.md)
- [LXC240 – Vaultwarden](../nodes/lxc240.md)
- [LXC250 – DevOps](../nodes/lxc250.md)
- [LXC260 – PostgreSQL](../nodes/lxc260.md)

## Services

- [Jellyfin](../services/jellyfin.md)
- [Audiobookshelf](../services/audiobookshelf.md)
- [Nextcloud](../services/nextcloud.md)
- [Paperless-ngx](../services/paperless.md)
- [Calibre-Web](../services/calibre-web.md)
- [OpenWebUI](../services/openwebui.md)
- [Ollama](../services/ollama.md)
- [Vaultwarden](../services/vaultwarden.md)
- [PostgreSQL Platform](../services/postgresql-platform.md)

## Platform

- [Storage Design](../platform/storage-design.md)
- [Samba](../platform/samba.md)
- [Monitoring](../platform/monitoring.md)
- [Tailscale ACL](../platform/tailscale-acl.md)
- [Networking](../platform/networking.md)
- [Operations](../platform/operations.md)
