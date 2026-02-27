# Homelab Platform Architecture


## Documentation

- Architecture overview: [docs/architecture/overview.md](docs/architecture/overview.md)
- Logical architecture diagram (Mermaid): [docs/architecture/diagram.md](docs/architecture/diagram.md)
- Exposure model diagram (Mermaid): [docs/architecture/exposure-diagram.md](docs/architecture/exposure-diagram.md)
- Design decisions (trade-offs): [docs/decisions/design-decisions.md](docs/decisions/design-decisions.md)
- Operations (runbooks, recovery): [docs/platform/operations.md](docs/platform/operations.md)
- Storage design (SnapRAID + MergerFS): [docs/platform/storage-design.md](docs/platform/storage-design.md)
- Samba model (VM102): [docs/platform/samba.md](docs/platform/samba.md)

---

[![Proxmox](https://img.shields.io/badge/Proxmox-Virtualization-E57000?logo=proxmox&logoColor=white)](https://www.proxmox.com/) [![Docker](https://img.shields.io/badge/Docker-Containerized-2496ED?logo=docker&logoColor=white)](https://www.docker.com/) [![SnapRAID](https://img.shields.io/badge/SnapRAID-Parity--Based-6A5ACD)](https://www.snapraid.it/) [![MergerFS](https://img.shields.io/badge/MergerFS-Union--Filesystem-5C2D91)](https://github.com/trapexit/mergerfs) [![Zero Trust](https://img.shields.io/badge/Security-Zero--Trust-111111)](https://en.wikipedia.org/wiki/Zero_trust_security_model) [![Tailscale](https://img.shields.io/badge/Tailscale-Overlay--Network-0047AB?logo=tailscale&logoColor=white)](https://tailscale.com/) [![Prometheus](https://img.shields.io/badge/Prometheus-Monitoring-E6522C?logo=prometheus&logoColor=white)](https://prometheus.io/) [![Grafana](https://img.shields.io/badge/Grafana-Observability-F46800?logo=grafana&logoColor=white)](https://grafana.com/)



> A self-designed, security-focused platform architecture built on Proxmox.

This project models real-world platform engineering principles and serves as a structured environment to deliberately practice architectural decision-making, operational discipline, and recovery-oriented design.

It is not built as a collection of services, but as a layered infrastructure platform with explicit trade-offs, documented design decisions, and clearly defined trust boundaries.

---

## Architectural Intent

This homelab is intentionally structured around:

- Clear separation of responsibility layers
- Deterministic reboot behavior
- Storage abstraction with explicit trade-offs
- Identity-based access control
- Least-privilege service segmentation
- Observability-first operations
- Recovery-focused design

---

## Quick Overview

| Layer | Component | Purpose |
|-------|----------|---------|
| Hypervisor | Proxmox | Virtualization platform |
| Storage | SnapRAID + MergerFS | Parity protection + flexible expansion |
| Compute | Docker on VM100 | GPU-enabled workloads |
| Services | Unprivileged LXCs | Isolation and segmentation |
| Access | Tailscale | Identity-based remote access |
| Monitoring | Prometheus + Grafana | Observability layer |

---

## Scope & Limitations

This platform is not designed as a high-availability (HA) cluster.

It prioritizes deterministic recovery, explicit dependency modeling, and documented failure procedures over automatic failover.

The focus is operational clarity and controlled recovery rather than zero-downtime guarantees.

---






> A layered infrastructure designed with platform engineering principles and a Zero-Trust access model.

---

## Architecture Overview

The system is built on Proxmox and structured into clear responsibility layers:

### Storage Layer – VM102
- SnapRAID (parity-based protection)
- MergerFS (namespace abstraction)
- SMB3 (segmented least-privilege exports)

### Compute Layer – VM100
- Docker-based workloads
- NVIDIA GPU passthrough
- Read-only media mounts
- LAN-optimized streaming

### Service Layer – Unprivileged LXCs
- Nextcloud
- Vaultwarden
- Calibre-Web
- Monitoring (Prometheus + Grafana)

📌 **Logical Architecture Diagram**  
→ [View Architecture Diagram](docs/architecture/diagram.md)

---

## Security Model (Zero Trust)

- No public ingress
- No router port forwarding
- Identity-bound remote access via Tailscale
- No implicit network trust
- Strict least-privilege SMB segmentation
- Unprivileged containers

Remote access path:

Internet → Tailscale → Services

LAN exposure is restricted to media workloads only.

📌 **Exposure Model**  
→ [View Exposure Diagram](docs/architecture/exposure-diagram.md)

---

## Storage Architecture

- SnapRAID for parity protection (scheduled sync)
- MergerFS for flexible disk growth
- Heterogeneous ext4 data disks
- Service-specific segmented shares

📌 **Storage Design Documentation**  
→ [View Storage Design](docs/platform/storage-design.md)

---

## Operational Model

- Reboot-safe mounts (fstab + systemd)
- Explicit dependency layering
- Documented recovery procedures
- Monitoring independent from application layer

📌 **Operations Documentation**  
→ [View Operations Model](docs/platform/operations.md)

---

## Core Technologies

Proxmox · Debian · Ubuntu · Docker · SnapRAID · MergerFS · Samba · Prometheus · Grafana · Tailscale

---

## Design Philosophy

This infrastructure prioritizes:

- Deterministic recovery
- Security through segmentation
- Explicit trust boundaries
- Operational transparency
- Documented trade-offs

The goal is predictable behavior under failure and controlled exposure.

