# Operations & Maintenance

This document describes the operational model of the homelab infrastructure: monitoring, maintenance routines, dependency ordering, recovery procedures, and the security posture.

The goal is **reboot-safe**, **least-privilege**, and **operationally explainable** infrastructure (runbook-friendly, deterministic recovery).

---

## 0. System Overview (Operational View)

### Core Building Blocks

- **Proxmox Host** (hypervisor): runs VMs and LXCs, provides boot ordering and isolation boundaries
- **VM102 (Storage VM)**: SnapRAID + MergerFS + Samba exports (single source of truth for persistent data)
- **VM100 (GPU/Compute VM)**: Docker workloads for media services (Jellyfin/Audiobookshelf), GPU passthrough
- **Service LXCs**:
  - **LXC200**: Monitoring (Prometheus + Grafana + Node Exporter)
  - **LXC210**: Nextcloud (classic stack: Apache + PHP + MariaDB + Redis)
  - **LXC212**: Calibre-Web (Docker in LXC)
  - **LXC230**: Vaultwarden (Docker in LXC)

### Trust Boundaries

- **Public Internet:** no direct exposure, no router port-forwarding
- **LAN:** limited exposure (media services intentionally LAN-reachable for performance)
- **Overlay network (Tailscale):** identity-based access for administration and remote usage
- **Storage boundary:** strong segmentation at SMB layer (RW vs RO consumer identities)

---

## 1. Monitoring (Observability Baseline)

### Stack (LXC200)

- **Prometheus**: metrics collection
- **Node Exporter**: system metrics
- **Grafana**: dashboards (visualization)

### Exposure Model

- Prometheus: `127.0.0.1:9090`
- Grafana: `127.0.0.1:3000`
- Node Exporter: `127.0.0.1:9100`
- Remote access via the **zero-trust overlay model (Tailscale)**

### Monitored Layers (Current/Target)

- Proxmox host
- Storage VM (VM102)
- GPU VM (VM100)
- Service LXCs (210/212/230)
- Monitoring LXC itself (200)

### Key Metrics (Minimum Set)

- **Compute:** CPU load, RAM usage, swap pressure
- **Storage:** disk usage, inode usage, filesystem saturation, IO wait
- **Containers:** uptime, restart count, healthchecks
- **Network:** interface errors, bandwidth (where relevant)
- **SnapRAID:** last sync age, scrub age, detected errors (manual now; automation planned)

### Planned Enhancements

- SMART metrics integration (either `smartctl_exporter` or node-exporter textfile collector)
- Alerting with Alertmanager (routing via SMTP or webhook)
- “Golden signals” dashboards per tier (Storage/Compute/Services)

---

## 2. Data Protection & Backup Strategy

### 2.1 SnapRAID (VM102)

SnapRAID provides **parity-based** protection for the MergerFS-backed data disks.

- Protection type: **not real-time**
- Sync model: scheduled/manual
- Integrity model: scrub/rehash over time

Operational expectations:

- Run `snapraid status` regularly
- Run `snapraid sync` after large write operations (or via schedule once implemented)
- Run `snapraid scrub` on a defined cadence

Risk profile:

- Good for mostly-static large media libraries
- Less optimal for highly dynamic datasets unless sync/scrub is frequent and procedures are tight

### 2.2 MergerFS (VM102)

MergerFS provides a **unified namespace only**:

- No redundancy
- No parity
- No replication

It is an abstraction layer to keep service paths stable while disks are added/removed/rebalanced.

### 2.3 Service Data (Current State)

- **Vaultwarden**: SQLite (`/opt/vaultwarden/db.sqlite3*`) + RSA keys  
  - Backup approach: filesystem-level backups (and/or scheduled copy to backup folder)  
  - Future: verified restore tests + retention strategy
- **Nextcloud**:
  - User data lives on mounted storage (`/mnt/nextcloud` in LXC210)
  - DB is local MariaDB (inside container)
  - Future improvement: automated DB dumps + integrity verification

### 2.4 Backup Scope & Residual Risk

Current stance:

- Protects against **single disk failures** (within SnapRAID constraints)
- Does **not** protect against:
  - accidental deletion if synced after deletion
  - ransomware inside RW shares
  - full-site disasters (no off-site)

Planned improvements:

- Off-site backup for critical subsets (password vault exports, Nextcloud DB + config, important documents)
- Immutable or append-only backup target (e.g. restic + append-only repo, or object storage)

---

## 3. Startup & Dependency Modeling (Reboot-Safe Operation)

### 3.1 Dependency Layers (Boot Order)

**Layer 0: Hypervisor**
- Proxmox up, networking stable

**Layer 1: Storage**
- VM102 online
- All disks mounted (`/mnt/disk*`, `/mnt/parity`)
- MergerFS mounted at `/mnt/mergerfs`
- Samba running and reachable

**Layer 2: Compute**
- VM100 online
- Data disk mounted at `/mnt/vm-data`
- Media mounts available (autofs/systemd automount)

**Layer 3: Services**
- LXCs online (210/212/230/200)
- Each service has its mounts online before starting critical workloads
- Docker containers restart via `restart: unless-stopped` (where applicable)

**Layer 4: Validation**
- Monitoring confirms that targets are UP
- Spot-check service endpoints via loopback/Tailscale

### 3.2 Mount Strategy (Principle)

- Storage VM: `/etc/fstab` (systemd-generated mount units) for ext4 + MergerFS
- Consumers: **systemd automount** for CIFS (reboot-safe, avoids hard failure on boot if storage temporarily unavailable)
- Services mount RO where possible (least-privilege)

### 3.3 Operational Invariant

After a reboot, the system should converge automatically to:

- mounts present
- services running
- monitoring reporting healthy states

No manual “click-to-mount” steps should exist.

---

## 4. Incident Response Playbooks (Common Failure Scenarios)

### 4.1 Disk Failure (SnapRAID Data Disk)

Symptoms:

- missing `/mnt/diskXX`
- IO errors, filesystem read-only remount
- SnapRAID reports missing disk/content

High-level recovery steps:

1. Replace disk (hardware)
2. Recreate filesystem and mountpoint
3. Restore data using SnapRAID (`fix` workflow)
4. Validate integrity and re-sync parity

### 4.2 Parity Disk Failure

Symptoms:

- `/mnt/parity` missing or unreadable
- SnapRAID parity file inaccessible

Recovery steps:

1. Replace parity disk
2. Recreate filesystem and mountpoint
3. Rebuild parity (`snapraid sync`)
4. Run scrub cycle after rebuild

### 4.3 MergerFS Mount Failure

Symptoms:

- `/mnt/mergerfs` missing
- services fail due to missing paths

Actions:

- Validate all underlying disk mounts exist
- Inspect systemd mount unit generated from fstab
- Check journal for fuse/mergerfs errors
- Ensure `allow_other` and `user_allow_other` are correct (if applicable)

### 4.4 CIFS Mount Failure in Service LXC/VM

Symptoms:

- `/books`, `/mnt/nextcloud`, etc. missing or empty
- services start but show “library missing” / “data dir missing”
- `systemctl --failed` shows mount/automount unit failure

Actions:

- Inspect `findmnt -T <path>`
- Inspect corresponding systemd unit and logs
- Verify credentials file permissions and username correctness
- Verify Samba service availability on VM102
- Validate UID/GID mapping expectations (especially unprivileged LXCs)

### 4.5 Container Failure / Restart Loops

Symptoms:

- `docker ps` shows restarts
- unhealthy healthcheck
- application logs indicate missing mounts or permissions

Actions:

- Confirm mounts exist **before** debugging app-level issues
- Check container logs
- Verify container user/UID/GID alignment
- Verify loopback-only binding where intended

---

## 5. Security Posture (Current State)

### 5.1 Exposure Rules

- No public reverse proxy
- No router port-forwarding
- Internal services bind to loopback where possible
- Media services may be LAN-bound for performance trade-offs

### 5.2 Zero-Trust Overlay (Tailscale)

- Identity-based overlay network for remote access
- Services that must be remote-accessible (e.g., Nextcloud) use Tailscale DNS/certs patterns
- Admin and service segmentation is enforced through the overlay model (policy-driven)

### 5.3 Least Privilege (Storage + Services)

- RW shares only where required:
  - Nextcloud, Vaultwarden
- RO shares for consumers:
  - Jellyfin, Audiobookshelf, Calibre-Web
- Consistent UID/GID handling across boundaries to avoid permission drift

---

## 6. Maintenance Routines (Recommended Cadence)

### Daily (lightweight)

- Check monitoring dashboards for anomalies
- Quick sanity:
  - key services reachable (loopback/Tailscale)
  - storage usage not near saturation

### Weekly

- `snapraid status` review
- check scrub age and plan scrub window
- review container restarts / errors

### Monthly

- SnapRAID scrub (cadence depends on dataset churn)
- Review disk SMART health (once integrated)
- Validate that backups can be restored (spot test)

### After Major Changes

- Reboot-safe validation:
  - reboot storage -> confirm mergerfs + samba
  - reboot service nodes -> confirm automount + services
  - check monitoring target health after each layer

---

## 7. Future Improvements (Roadmap)

- Automated SnapRAID sync + scrub schedule (with logging + notifications)
- SMART monitoring integration + alerting
- Off-site backups for critical datasets (Nextcloud DB/config, Vault exports)
- IaC-style documentation:
  - compose files in repo (sanitized)
  - systemd units snippets (sanitized)
  - ACL/policy documentation for overlay network

