# Architecture Overview

The infrastructure is modular and responsibility-driven. It is designed around clear separation of concerns (compute vs. storage vs. services) and reboot-safe operation.

## Components

### Hypervisor (Proxmox VE)

- Hosts VMs and unprivileged LXCs
- Startup order modeled to ensure dependencies are met during reboot

### VM102 – Storage

- Dedicated storage VM (Debian)
- MergerFS pooled storage
- SnapRAID parity-based protection
- Exports storage to service containers via controlled mounts/shares

### VM100 – Compute / GPU

- Dedicated compute VM (Ubuntu)
- Docker + Docker Compose for media services
- NVIDIA GPU passthrough for hardware acceleration
- Media directories mounted via systemd automount (autofs) to support reboot-safe operation

### LXC200 – Monitoring

- Dedicated monitoring container
- Prometheus + Grafana + Node Exporter

### Service LXCs

- LXC210 – Nextcloud (not containerized via Docker)
- LXC212 – Calibre-Web (Docker in LXC)
- LXC230 – Vaultwarden (Docker in LXC, UID/GID pinning)

## Design Principles

- Separation of concerns (compute, storage, services)
- Minimal coupling between components
- Zero-trust inspired access model (no public reverse proxy / no router port forwarding)
- Least privilege access (RO/RW separation where applicable)
- Reboot-safe operation (mount and startup dependency modeling)
