# Homelab Platform Architecture

A fully documented, layered homelab infrastructure designed using **platform engineering principles** and a **Zero-Trust access model**.

The system emphasizes:

- Clear separation of **storage, compute and access layers**
- Explicit **security segmentation**
- Identity-based **Zero-Trust remote access**
- Deterministic **recovery and failure handling**
- Reboot-safe dependency modeling

This repository documents the architecture, operational model and design decisions behind the system.

---

## Executive Overview

The infrastructure is built on a Proxmox hypervisor and follows a strict responsibility-driven design:

### VM102 – Storage Layer
- SnapRAID (parity-based data protection)
- MergerFS (unified namespace abstraction)
- SMB3 with enforced signing
- Least-privilege segmented service exports

### VM100 – Compute / Media Layer
- Docker-based workloads
- GPU acceleration (NVIDIA passthrough)
- Read-only media mounts
- LAN-optimized streaming

### Service LXCs
- Nextcloud
- Vaultwarden
- Calibre-Web
- Monitoring (Prometheus + Grafana)

Each layer has clearly defined responsibilities and controlled trust boundaries.

---

## Architecture Model

The system follows a layered architecture:

- Storage isolated from compute
- Compute isolated from access layer
- Explicit dependency chain
- Deterministic startup behavior
- Documented recovery paths

📌 Logical Architecture Diagram  
→ `docs/architecture-diagram.md`

📌 Exposure / Security Model  
→ `docs/exposure-diagram.md`

---

## Storage Design

- SnapRAID for parity-based protection (not real-time RAID)
- MergerFS for namespace abstraction across heterogeneous disks
- Ext4 data disks
- Per-service SMB segmentation
- Read-only mounts for consumer services where possible

📌 Full storage documentation  
→ `docs/storage-design.md`

---

## Security Model

The system follows a **Zero-Trust access model**:

- No public ingress
- No router port forwarding
- No direct Internet-exposed services
- Identity-bound remote access via Tailscale
- No implicit network trust
- Unprivileged LXC containers
- Strict SMB least-privilege enforcement

Remote access path:

Internet → Tailscale (identity verification) → Services

LAN exposure is limited to media services for performance reasons.  
All other services require identity-based access.

📌 Design decisions & trade-offs  
→ `docs/design-decisions.md`

---

## Operational Model

- Reboot-safe mounts via fstab / systemd
- Explicit dependency startup order
- SnapRAID sync + verification workflow
- Monitoring isolated from application layer
- Documented failure scenarios and recovery steps

📌 Operational documentation  
→ `docs/operations.md`

---

## Core Technologies

- Proxmox VE
- Debian (Storage VM)
- Ubuntu (GPU VM)
- Docker / Docker Compose
- SnapRAID
- MergerFS
- Samba (SMB3 with signing)
- Prometheus
- Grafana
- Tailscale (Zero-Trust overlay network)

---

## Design Philosophy

This infrastructure prioritizes:

- Deterministic recovery over convenience
- Security through segmentation
- Explicit trust boundaries
- Minimal coupling between layers
- Operational transparency
- Documented trade-offs instead of hidden assumptions

The objective is predictable behavior under failure and controlled exposure —  
not maximum feature density.

