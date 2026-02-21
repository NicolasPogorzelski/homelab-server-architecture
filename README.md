# Homelab Platform Architecture

![Proxmox](https://img.shields.io/badge/Proxmox-Virtualization-E57000?logo=proxmox&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-Containerized-2496ED?logo=docker&logoColor=white)
![SnapRAID](https://img.shields.io/badge/SnapRAID-Parity--Based-6A5ACD)
![MergerFS](https://img.shields.io/badge/MergerFS-Union--Filesystem-5C2D91)
![Zero Trust](https://img.shields.io/badge/Security-Zero--Trust-111111)
![Tailscale](https://img.shields.io/badge/Tailscale-Overlay--Network-0047AB?logo=tailscale&logoColor=white)
![Prometheus](https://img.shields.io/badge/Prometheus-Monitoring-E6522C?logo=prometheus&logoColor=white)
![Grafana](https://img.shields.io/badge/Grafana-Observability-F46800?logo=grafana&logoColor=white)


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
→ [View Architecture Diagram](docs/architecture-diagram.md)

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
→ [View Exposure Diagram](docs/exposure-diagram.md)

---

## Storage Architecture

- SnapRAID for parity protection (scheduled sync)
- MergerFS for flexible disk growth
- Heterogeneous ext4 data disks
- Service-specific segmented shares

📌 **Storage Design Documentation**  
→ [View Storage Design](docs/storage-design.md)

---

## Operational Model

- Reboot-safe mounts (fstab + systemd)
- Explicit dependency layering
- Documented recovery procedures
- Monitoring independent from application layer

📌 **Operations Documentation**  
→ [View Operations Model](docs/operations.md)

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

