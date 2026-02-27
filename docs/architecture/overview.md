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
- Zero-trust inspired access model (no public internet exposure (access restricted to private overlay network))
- Least privilege access (RO/RW separation where applicable)
- Reboot-safe operation (mount and startup dependency modeling)

## Networking Layer

- Zero-trust inspired access model
- Identity-based overlay networking (Tailscale)
- Explicit ACL segmentation between tiers
- No public service exposure

## Services

- [VM100 (GPU VM) – Jellyfin & Audiobookshelf](services-vm100.md)
- [Nextcloud (LXC210)](nextcloud.md)
- [Calibre-Web (LXC212)](calibre-web.md)
- [Vaultwarden (LXC230)](vaultwarden.md)
- [Monitoring (LXC200)](monitoring.md)


## Storage Docs

- [Storage Design (SnapRAID + MergerFS)](storage-design.md)
- [Samba Shares (VM102)](samba.md)

See: [docs/platform/tailscale-acl.md](docs/platform/tailscale-acl.md)
