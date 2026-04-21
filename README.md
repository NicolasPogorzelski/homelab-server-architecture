# Homelab Platform Architecture

[![Proxmox](https://img.shields.io/badge/Proxmox-Virtualization-E57000?logo=proxmox&logoColor=white)](https://www.proxmox.com/) [![Docker](https://img.shields.io/badge/Docker-Containerized-2496ED?logo=docker&logoColor=white)](https://www.docker.com/) [![SnapRAID](https://img.shields.io/badge/SnapRAID-Parity--Based-6A5ACD)](https://www.snapraid.it/) [![MergerFS](https://img.shields.io/badge/MergerFS-Union--Filesystem-5C2D91)](https://github.com/trapexit/mergerfs) [![Zero Trust](https://img.shields.io/badge/Security-Zero--Trust-111111)](https://en.wikipedia.org/wiki/Zero_trust_security_model) [![Tailscale](https://img.shields.io/badge/Tailscale-Overlay--Network-0047AB?logo=tailscale&logoColor=white)](https://tailscale.com/) [![Prometheus](https://img.shields.io/badge/Prometheus-Monitoring-E6522C?logo=prometheus&logoColor=white)](https://prometheus.io/) [![Grafana](https://img.shields.io/badge/Grafana-Observability-F46800?logo=grafana&logoColor=white)](https://grafana.com/)

> A self-designed, security-focused platform architecture built on Proxmox.

This project models real-world platform engineering principles and serves as a structured environment to deliberately practice architectural decision-making, operational discipline, and recovery-oriented design.

It is not built as a collection of services, but as a layered infrastructure platform with explicit trade-offs, documented design decisions, and clearly defined trust boundaries.

---

## Quick Overview

| Layer | Component | Purpose |
|-------|-----------|---------|
| Hypervisor | Proxmox | Virtualization platform |
| Storage | SnapRAID + MergerFS | Parity protection + flexible expansion |
| Compute | Docker on VM100 | GPU-enabled workloads |
| Services | Unprivileged LXCs | Isolation and segmentation |
| Access | Tailscale | Identity-based remote access (Zero Trust) |
| Monitoring | Prometheus + Grafana | Observability layer |

This platform is not designed for high availability. It prioritizes deterministic recovery, explicit dependency modeling, and documented failure procedures over automatic failover.

---

## Documentation

### Architecture

- [Architecture Overview](docs/architecture/overview.md)
- [Logical Architecture Diagram](docs/architecture/diagram.md) (Mermaid)
- [Exposure Model Diagram](docs/architecture/exposure-diagram.md) (Mermaid)

### Decisions

- [Design Decisions](docs/decisions/design-decisions.md) (trade-offs and rationale)
- [Loopback + Tailscale Serve](docs/decisions/loopback-tailscale-serve.md) (binding pattern ADR)
- [LXC250 DevOps Workstation](docs/decisions/lxc250-devops.md) (central management node ADR)

### Nodes

- [VM100 – GPU / Compute](docs/nodes/vm100.md) (Docker, NVIDIA, Jellyfin, Audiobookshelf)
- [VM102 – Storage](docs/nodes/vm102.md) (SnapRAID, MergerFS, Samba)
- [LXC200 – Monitoring](docs/nodes/lxc200.md) (Prometheus, Grafana, Node Exporter)
- [LXC210 – Nextcloud](docs/nodes/lxc210.md) (Apache, PHP, MariaDB, Redis)
- [LXC220 – Calibre-Web](docs/nodes/lxc220.md) (Docker in LXC)
- [LXC230 – OpenWebUI](docs/nodes/lxc230.md) (AI stack, Docker in LXC)
- [LXC240 – Vaultwarden](docs/nodes/lxc240.md) (Docker in LXC, secrets tier)
- [LXC250 – DevOps](docs/nodes/lxc250.md) (Git, Ansible, IaC)
- [LXC260 – PostgreSQL](docs/nodes/lxc260.md) (centralized platform database)

### Services

- [Jellyfin](docs/services/jellyfin.md)
- [Audiobookshelf](docs/services/audiobookshelf.md)
- [Nextcloud](docs/services/nextcloud.md)
- [Paperless-ngx](docs/services/paperless.md)
- [Calibre-Web](docs/services/calibre-web.md)
- [OpenWebUI](docs/services/openwebui.md)
- [Ollama](docs/services/ollama.md)
- [Vaultwarden](docs/services/vaultwarden.md)
- [PostgreSQL Platform](docs/services/postgresql-platform.md)

### Platform

- [Storage Design](docs/platform/storage-design.md) (SnapRAID + MergerFS)
- [Samba](docs/platform/samba.md) (segmented exports, least privilege)
- [Monitoring](docs/platform/monitoring.md) (Prometheus + Grafana stack)
- [Networking](docs/platform/networking.md) (Zero-Trust model)
- [Tailscale ACL](docs/platform/tailscale-acl.md) (policy-as-code, tier model)
- [Operations](docs/platform/operations.md) (runbooks, recovery, maintenance)
- [Known Errors](docs/platform/known-errors.md) (observed issues and workarounds)

### Runbooks

- [Runbook Index](runbooks/README.md)
- [PostgreSQL Backup & Restore](runbooks/database/pg-backup.md)
