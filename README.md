# Homelab Platform Architecture

[![Validate Repository](https://github.com/NicolasPogorzelski/homelab-server-architecture/actions/workflows/validate-repo.yml/badge.svg?branch=main)](https://github.com/NicolasPogorzelski/homelab-server-architecture/actions/workflows/validate-repo.yml) [![Ansible-lint](https://github.com/NicolasPogorzelski/homelab-server-architecture/actions/workflows/ansible-lint.yml/badge.svg?branch=main)](https://github.com/NicolasPogorzelski/homelab-server-architecture/actions/workflows/ansible-lint.yml) [![Image vulnerability scan](https://github.com/NicolasPogorzelski/homelab-server-architecture/actions/workflows/image-scan.yml/badge.svg?branch=main)](https://github.com/NicolasPogorzelski/homelab-server-architecture/actions/workflows/image-scan.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-green)](LICENSE)

[![Proxmox](https://img.shields.io/badge/Proxmox-Virtualization-E57000?logo=proxmox&logoColor=white)](https://www.proxmox.com/) [![Ansible](https://img.shields.io/badge/Ansible-Configuration--Management-EE0000?logo=ansible&logoColor=white)](https://www.ansible.com/) [![Docker](https://img.shields.io/badge/Docker-Containerized-2496ED?logo=docker&logoColor=white)](https://www.docker.com/) [![Prometheus](https://img.shields.io/badge/Prometheus-Monitoring-E6522C?logo=prometheus&logoColor=white)](https://prometheus.io/) [![Grafana](https://img.shields.io/badge/Grafana-Observability-F46800?logo=grafana&logoColor=white)](https://grafana.com/) [![Tailscale](https://img.shields.io/badge/Tailscale-Overlay--Network-0047AB?logo=tailscale&logoColor=white)](https://tailscale.com/) [![Zero Trust](https://img.shields.io/badge/Security-Zero--Trust-111111)](https://en.wikipedia.org/wiki/Zero_trust_security_model) [![PostgreSQL](https://img.shields.io/badge/PostgreSQL-Platform--Database-4169E1?logo=postgresql&logoColor=white)](https://www.postgresql.org/) [![SnapRAID](https://img.shields.io/badge/SnapRAID-Parity--Based-6A5ACD)](https://www.snapraid.it/)

## About

Built by Nicolas Pogorzelski as a deliberate learning environment for a career transition into DevOps and platform engineering. The emphasis is on cost-aware, risk-conscious engineering - explicit trade-offs over cargo-culted complexity. Incidents are documented, post-mortems written, and every failure turned into a runbook or known-error entry.

A self-designed, security-focused platform architecture built on Proxmox.

This project models real-world platform engineering principles and serves as a structured environment to deliberately practice architectural decision-making, operational discipline, and recovery-oriented design.

It is not built as a collection of services, but as a layered infrastructure platform with explicit trade-offs, documented design decisions, and clearly defined trust boundaries.

## At a glance

```mermaid
flowchart TB
  Admin(["Admin devices"])
  TVs(["Household TVs"])

  TS["Tailscale overlay<br/>identity-based ACL, tier model<br/>no port-forwarding, no public reverse proxy"]

  subgraph host["Proxmox host - single node, recovery-oriented, no HA"]
    VM100["VM100 - GPU compute<br/>Jellyfin, Audiobookshelf, Ollama"]
    LXC["7 service LXCs<br/>Nextcloud, Paperless-ngx, Calibre-Web,<br/>OpenWebUI, Vaultwarden, PostgreSQL, Monitoring"]
    CTRL["LXC250 - Ansible control node"]
    VM102["VM102 - storage<br/>SnapRAID + MergerFS + Samba"]
  end

  Admin --> TS
  TVs -->|LAN, media ports only| VM100
  TS --> VM100
  TS --> LXC
  TS --> CTRL
  CTRL -->|SSH, 9 managed nodes| VM100
  CTRL -->|SSH| LXC
  VM100 -->|CIFS over Tailscale| VM102
  LXC -->|host CIFS mounts, bind-mounted in| VM102

  classDef access fill:#0b3d6b,stroke:#0b3d6b,color:#ffffff
  classDef compute fill:#1f6f43,stroke:#1f6f43,color:#ffffff
  classDef storage fill:#6a4a9c,stroke:#6a4a9c,color:#ffffff
  classDef control fill:#8a5a00,stroke:#8a5a00,color:#ffffff
  class TS,Admin,TVs access
  class VM100,LXC compute
  class VM102 storage
  class CTRL control
```

Two detailed views follow from here: the [logical architecture](docs/architecture/diagram.md), split
into access paths, storage dependencies and monitoring coverage, and the
[exposure model](docs/architecture/exposure-diagram.md).

## Documentation standard

Any statement here that carries a number was measured against the running system rather than
estimated, and the command that produced it is usually quoted alongside. Where a claim later turned
out to be wrong, it is corrected in place with the correction visible, not silently overwritten -
the [changelog](docs/platform/changelog.md) and the [known-error
register](docs/platform/known-errors.md) carry more corrections than announcements, on purpose.

Runbooks that have been executed record the date and the result. Four of thirteen currently do;
the rest have not been run against a real incident, and saying so is more useful than a claim the
files do not support. This paragraph asserted that every runbook carried such a record until an
audit on 2026-08-17 checked it.

---

## Learning Roadmap

| Phase | Topic | Status |
|---|---|---|
| 1 | Linux, Bash, Git, Networking | Done |
| 2 | Docker + Compose | Done |
| 3 | Monitoring - Prometheus, Grafana, Alertmanager | Done |
| 4 | Zero Trust Networking - Tailscale, ACL design | Done |
| 5 | Ansible - playbooks, roles, vault, hardening | Done |
| 6 | Terraform - IaC on AWS (free tier) + Proxmox provisioning | Planned |
| 7 | Kubernetes - k3s in the homelab | Planned |
| 8 | Cloud depth (AWS) + Python | Planned |

Bash scripting runs cross-cutting throughout; Disaster Recovery and Security are practiced continuously rather than as a single phase. Targeted certifications: Terraform Associate, then AWS Solutions Architect Associate.

---

## Quick Overview

| Layer | Component | Purpose |
|-------|-----------|---------|
| Hypervisor | Proxmox | Virtualization platform |
| Storage | SnapRAID + MergerFS | Parity protection + flexible expansion |
| Compute | Docker on VM100 | GPU-enabled workloads |
| Services | Unprivileged LXCs | Isolation and segmentation |
| Configuration | Ansible | Declarative management of every guest; roles, inventory, vault |
| Access | Tailscale | Identity-based remote access (Zero Trust) |
| Monitoring | Prometheus + Grafana | Observability layer |

This platform is not designed for high availability. It prioritizes deterministic recovery, explicit dependency modeling, and documented failure procedures over automatic failover.

---

## How to read this repository

Three entry points, depending on what you came for. Each is one document that links onward.

| If you want to see | Start at |
|---|---|
| How it is built and why the trade-offs went the way they did | [Design Decisions](docs/decisions/design-decisions.md), then the [architecture diagram](docs/architecture/diagram.md) |
| How it is run, and what has broken | [Known Errors](docs/platform/known-errors.md) and the [Platform Changelog](docs/platform/changelog.md) |
| How it is secured, and where it is not | [Security Controls](docs/platform/security-controls.md) and [Data Classification](docs/platform/data-classification.md) |

The single best illustration of how decisions are made here is
[SMB bind and LAN access](docs/decisions/smb-bind-and-lan-access.md): a rule the platform sets for
itself, a service that cannot follow it, three attempts measured and rejected, and the boundary
moved one layer down instead - with the reboot that proves it.

---

## Documentation

### Architecture

- [Architecture Overview](docs/architecture/overview.md)
- [Logical Architecture Diagram](docs/architecture/diagram.md) (Mermaid)
- [Exposure Model Diagram](docs/architecture/exposure-diagram.md) (Mermaid)

### Decisions

- [Design Decisions](docs/decisions/design-decisions.md) (trade-offs and rationale)
- [SMB Bind and LAN Access](docs/decisions/smb-bind-and-lan-access.md) (a rule the service cannot follow, enforced one layer down)
- [Loopback + Tailscale Serve](docs/decisions/loopback-tailscale-serve.md) (binding pattern ADR)
- [Calibre Auto-Import on CIFS](docs/decisions/calibre-cifs-sqlite-import.md) (SQLite byte-range locking over SMB)
- [PostgreSQL Tailscale Boot Ordering](docs/decisions/postgresql-tailscale-boot-ordering.md) (ordering is not readiness)
- [pveproxy Tailscale Boot Ordering](docs/decisions/pveproxy-tailscale-boot-ordering.md) (the same race on the hypervisor)
- [LXC250 DevOps Workstation](docs/decisions/lxc250-devops.md) (central management node ADR)
- [Headscale Migration](docs/decisions/headscale-migration.md) (control plane sovereignty - deferred to Phase 6)

### Nodes

- [VM100 - GPU / Compute](docs/nodes/vm100.md) (Docker, NVIDIA, Jellyfin, Audiobookshelf)
- [VM102 - Storage](docs/nodes/vm102.md) (SnapRAID, MergerFS, Samba)
- [LXC200 - Monitoring](docs/nodes/lxc200.md) (Prometheus, Grafana, Node Exporter)
- [LXC210 - Nextcloud](docs/nodes/lxc210.md) (Apache, PHP, MariaDB, Redis)
- [LXC211 - Paperless-ngx](docs/nodes/lxc211.md) (Docker in LXC, document management)
- [LXC220 - Calibre-Web](docs/nodes/lxc220.md) (Docker in LXC)
- [LXC230 - OpenWebUI](docs/nodes/lxc230.md) (AI stack, Docker in LXC)
- [LXC240 - Vaultwarden](docs/nodes/lxc240.md) (Docker in LXC, secrets tier)
- [LXC250 - DevOps](docs/nodes/lxc250.md) (Git, Ansible, IaC)
- [LXC260 - PostgreSQL](docs/nodes/lxc260.md) (centralized platform database)

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
- [Ansible](docs/platform/ansible.md) (control node, inventory, vault, roles)
- [Proxmox Host](docs/platform/proxmox-host.md) (hypervisor-level config, boot ordering, power schedule)
- [Storage Permissions](docs/platform/storage-permissions.md) (the filesystem side of the share model, verified daily)
- [Operations](docs/platform/operations.md) (operational model, dependency layers, incident playbooks)

### Security, risk and change

- [Security Controls](docs/platform/security-controls.md) (ISO/IEC 27001 Annex A mapping - what is enforced, what is merely practised)
- [Data Classification](docs/platform/data-classification.md) (classification, recovery objectives, data protection assessment)
- [Remediation Plan](docs/platform/remediation-plan.md) (open work ordered by loss risk and dependency)
- [Known Errors](docs/platform/known-errors.md) (the corrective-action log, 20 entries with root causes)
- [Platform Changelog](docs/platform/changelog.md) (every change with the measurement that verified it)

### Incidents

- [aux-disk failure and recovery](docs/platform/incidents/2026-06-25-aux-disk-failure-and-recovery.md) (2026-06-25)
- [VM100 silent freeze](docs/platform/incidents/2026-07-11-vm100-silent-freeze.md) (2026-07-11)

### Runbooks

Thirteen procedures under the same contract: every one states its preconditions, its verification
step, its failure modes and its rollback - or records that no rollback exists and why, which for
`snapraid sync` is the whole point. Enforced by the validator, not by habit.

- [Runbook Index](runbooks/README.md)
- Database: [PostgreSQL backup](runbooks/database/pg-backup.md) - [PostgreSQL restore](runbooks/database/pg-restore.md) - [MariaDB backup](runbooks/database/mariadb-backup.md)
- Storage: [SnapRAID sync](runbooks/storage/snapraid-sync.md) - [SnapRAID scrub](runbooks/storage/snapraid-scrub.md) - [aux-disk failure rescue](runbooks/storage/aux-disk-failure-rescue.md) - [SMB automount trigger](runbooks/storage/smb-autofs-trigger.md)
- Platform: [hard shutdown recovery](runbooks/platform/hard-shutdown-recovery.md) - [LVM thin pool full](runbooks/platform/lvm-thin-pool-full.md) - [LXC250 rebuild](runbooks/platform/lxc250-rebuild.md) - [pveproxy boot race](runbooks/platform/pveproxy-tailscale-boot-race.md) - [Docker data-root migration](runbooks/platform/docker-data-root-migration.md)
- Services: [OpenWebUI health](runbooks/ai-stack/openwebui-health.md) - [Nextcloud/Paperless integration](runbooks/integration/nextcloud-paperless.md)

### Automation

Everything guest-side is Ansible-managed, and every scheduled job is a systemd timer with
`Persistent=true` - the host powers down overnight, so cron silently loses every slot it sleeps
through.

- [Ansible Platform Doc](docs/platform/ansible.md) - control node, inventory, vault, and the full
  catalogue of playbooks and roles
- [Playbooks](ansible/playbooks/) and [Roles](ansible/roles/) - 28 and 24 respectively
- [Ansible Inventory](ansible/inventory/hosts.yml.example) (sanitized - real IPs gitignored)
- [Repository validator](scripts/validate-repo.sh) - 24 structural checks, run by a pre-commit
  hook and by CI on every push
