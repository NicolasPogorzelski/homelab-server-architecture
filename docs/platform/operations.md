# Operations & Maintenance

This document describes the operational model of the homelab infrastructure: monitoring, maintenance routines, dependency ordering, recovery procedures, and the security posture.

The goal is reboot-safe, least-privilege, and operationally explainable infrastructure (runbook-friendly, deterministic recovery).

See: [Runbook index](../../runbooks/README.md)
See: [Known Errors & Workarounds](./known-errors.md)

---

## 0. System Overview (Operational View)

### Core Building Blocks

- **Proxmox Host** (hypervisor): runs VMs and LXCs, provides boot ordering and isolation boundaries
- **VM102 (Storage VM)**: SnapRAID + MergerFS + Samba exports (single source of truth for persistent data)
- **VM100 (GPU/Compute VM)**: Docker workloads for media services (Jellyfin/Audiobookshelf), GPU passthrough
- **Service LXCs**:
  - **LXC200**: Monitoring (Prometheus + Grafana + Node Exporter)
  - **LXC210**: Nextcloud (classic stack: Apache + PHP + MariaDB + Redis)
  - **LXC211**: Paperless-ngx (document management, Docker in LXC)
  - **LXC220**: Calibre-Web (Docker in LXC)
  - **LXC230**: OpenWebUI (AI stack entrypoint)
  - **LXC240**: Vaultwarden (Docker in LXC)
  - **LXC250**: DevOps (central management workstation; Git, Ansible, IaC)
  - **LXC260**: PostgreSQL platform service (centralized database)

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

The monitoring stack binds loopback and is reached through Tailscale Serve; per-port detail is in
[`lxc200.md`](../nodes/lxc200.md), including the one exception (Alertmanager's cluster port). Note
that the loopback binding described there applies to this stack only - it is not a fleet-wide
statement, and the node documents carry the per-node reality.

### Monitored Layers

The target list lives in [`monitoring.md`](monitoring.md) and is rendered from the inventory, so it
cannot drift from what Prometheus actually scrapes. It is not repeated here - this section carried a
hand-maintained copy until 2026-08-17 and had inverted the two facts that matter: it listed the
DevOps LXC, which is in no inventory group and therefore scraped by nobody, and omitted lxc230 and
lxc260, which are scraped. A duplicated list is worse than no list when the duplicate is the one
somebody reads.

### Key Metrics (Minimum Set)

- **Compute:** CPU load, RAM usage, swap pressure
- **Storage:** disk usage, inode usage, filesystem saturation, IO wait
- **Containers:** uptime, restart count, healthchecks
- **Network:** interface errors, bandwidth (where relevant)
- **SnapRAID:** last sync age (`SnapRAIDSyncStale` alert, >26h), scrub age (`SnapRAIDScrubStale` alert, >32d); automated via `snapraid-maintenance.sh` on VM102

### Planned Enhancements

- **SMART: the collector is deployed, the useful attributes are not exported.**
  `node-exporter-smarttext.sh` has run on the Proxmox host every 60 s since 2025-12 (textfile
  collector), but emits only `smart_health_passed` and `smart_temperature_celsius`. Measured
  2026-08-13, the failing aux-disk of [KE-13](./known-errors.md#ke-13) - 7680 unreadable sectors -
  exports `smart_health_passed 1`, because `Current_Pending_Sector` normalises to `054` against
  threshold `000` and can never trip the drive's self-assessment. What is missing is
  `Reported_Uncorrect`, `Current_Pending_Sector`, `Reallocated_Sector_Ct`, `Wear_Leveling_Count`,
  plus rules in the (currently empty) `smart` group. Disk-failure detection still rests on SnapRAID
  alerts. Blocked on the host becoming an Ansible node
- "Golden signals" dashboards per tier (Storage/Compute/Services)
- An external heartbeat, so a total outage produces an alert rather than silence - see the Tier 4
  entry in the [remediation plan](remediation-plan.md)

(Alertmanager was listed here as planned until 2026-08-17. It has been deployed on lxc200 with a
webhook receiver since June.)

---

## 2. Data Protection & Backup Strategy

### 2.1 SnapRAID (VM102)

SnapRAID provides parity-based protection for the MergerFS-backed data disks.

- Protection type: not real-time
- Sync model: scheduled/manual
- Integrity model: scrub/rehash over time

Operational expectations:

- Run `snapraid status` regularly
- `snapraid sync` runs daily at 23:00 via `snapraid-sync.timer`; run manually after large write operations if needed
- `snapraid scrub` runs monthly on the 1st at 20:00 via `snapraid-scrub.timer`
- Both timers trigger the template unit `snapraid-maintenance@.service` (instance = `sync` / `scrub`)
  and are managed by the `snapraid_maintenance` Ansible role. They replaced `/etc/cron.d/snapraid`
  on 2026-07-10: the host powers down before 23:00 on many nights, so the cron sync was skipped
  without a trace and never retried. `Persistent=true` runs the overdue sync at the next boot,
  and a failed run now raises the `SystemdUnitFailed` alert.
- Inspect with `systemctl list-timers 'snapraid-*'` and `journalctl -u snapraid-maintenance@sync`

Risk profile:

- Good for mostly-static large media libraries
- Less optimal for highly dynamic datasets unless sync/scrub is frequent and procedures are tight

### 2.2 MergerFS (VM102)

MergerFS provides a unified namespace only:

- No redundancy
- No parity
- No replication

It is an abstraction layer to keep service paths stable while disks are added/removed/rebalanced.

### 2.3 Service Data (Current State)

- **Vaultwarden**: SQLite (`/opt/vaultwarden/db.sqlite3*`) + RSA keys
  - Protection today: SnapRAID parity and nothing else. There is no export and no version history.
    This entry read "filesystem-level backups (and/or scheduled copy to backup folder)" until
    2026-08-17, which described an intention rather than a job that exists.
  - Parity is not backup: it protects against losing a disk, not against deletion, corruption or
    ransomware, because the next sync writes the damage into the parity.
  - A consistent export is the last open half of Tier 1 #3 in the
    [remediation plan](remediation-plan.md). See [`lxc240.md`](../nodes/lxc240.md).
- **Nextcloud**:
  - User data lives on mounted storage (`/mnt/nextcloud` in LXC210)
  - DB is local MariaDB (inside the container), dumped nightly to a dedicated share since
    2026-08-15 by the `mariadb_backup` role, verified at write time, with `MariaDBBackupStale`
    watching it - see the [runbook](../../runbooks/database/mariadb-backup.md)
  - The two halves live on different disks with different protection: files on the archive pool,
    database on the boot SSD. Restoring one without the other yields unusable data.
- **PostgreSQL Platform (LXC260)**:
  - Dedicated infrastructure container
  - Databases on local block storage (no CIFS) - on the host's aux-disk, which is the failing
    KE-13 drive; see [`lxc260.md`](../nodes/lxc260.md)
  - Nightly `pg_dumpall` via timer, verified at write time before the file gets its real name,
    stored on SMB separately from the runtime data
  - A full-cluster restore into a throwaway cluster runs monthly and is alerted on when stale
    (`PostgreSQLRestoreTestStale`). This line said the procedure "must be periodically validated"
    until 2026-08-17; it has been automated since 2026-08-13.
- **Paperless-ngx (LXC211)**:
  - Document files on MergerFS/SMB (originals, archive, thumbnails)
  - Database in centralized PostgreSQL (lxc260)
  - Backups via pg_dump (paperless_db) + document export
  - Runtime state on local block storage (aux-disk)

### 2.4 Backup Scope & Residual Risk

Current stance:

- Protects against single disk failures (within SnapRAID constraints)
- Does not protect against:
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
- Media mounts available under `/srv/media/*` (systemd automount, one unit per library since
  2026-08-16). This said `/mnt/vm-data` until 2026-08-17 - a path that no longer carries a mount.

**Layer 3: Services**
- LXCs online (200/210/211/220/230/240/250/260 - the list here omitted 230 and 260 until
  2026-08-17)
- Each service has its mounts online before starting critical workloads
- Docker containers restart via `restart: unless-stopped` (where applicable)

**Layer 4: Validation**
- Monitoring confirms that targets are UP
- Spot-check service endpoints via loopback/Tailscale

### 3.2 Mount Strategy (Principle)

- Storage VM: `/etc/fstab` (systemd-generated mount units) for ext4 + MergerFS
- Consumers: systemd automount for CIFS (reboot-safe, avoids hard failure on boot if storage temporarily unavailable)
- Services mount RO where possible (least-privilege)

### 3.3 Operational Invariant

After a reboot, the system should converge automatically to:

- mounts present
- services running
- monitoring reporting healthy states

No manual "click-to-mount" steps should exist.

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
- services start but show "library missing" / "data dir missing"
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

- Confirm mounts exist before debugging app-level issues
- Check container logs
- Verify container user/UID/GID alignment
- Verify loopback-only binding where intended

### 4.6 PostgreSQL Platform Failure

Symptoms:
- Applications cannot connect (connection refused / timeout)
- `pg_isready` fails
- Monitoring shows DB node down

Actions:
1. Verify Tailscale interface up
2. Validate bind address (Tailscale IP only)
3. Inspect PostgreSQL logs
4. Confirm pg_hba rules not modified
5. Restore from backup if corruption detected

Note:
Database runtime storage is local block storage.
Backups reside on SMB and are isolated from runtime failure.

---

## 5. Security Posture (Current State)

### 5.1 Exposure Rules

- No public reverse proxy
- No router port-forwarding
- Internal services bind to loopback where possible
- Infrastructure services bind to Tailscale only
- LAN exposure is limited to performance-critical media workloads and explicitly justified

**These are the rules, not a description of the current state.** Measured 2026-08-17, the fleet
deviates in several places that are documented on the nodes themselves rather than summarised here:
sshd binds the wildcard everywhere except lxc250, Apache on lxc210 binds `*:80`/`*:443`, Samba on
vm102 binds `0.0.0.0:445` for a reason it cannot avoid, and Jellyfin and Audiobookshelf are LAN-bound
by design. Every node carries a routable IPv6 address, so a wildcard bind is reachable from outside
unless the router blocks it - which is what the
[SMB bind decision](../decisions/smb-bind-and-lan-access.md) established for port 445 and answered
with a kernel filter. The open ones are tracked in the [remediation plan](remediation-plan.md).

### 5.2 Zero-Trust Overlay (Tailscale)

Remote access and service-to-service communication are enforced via an identity-based overlay network (Tailscale).

- All remote access requires authenticated Tailscale identity
- Service-to-service permissions are tag-based
- ACL rules are explicitly defined and port-scoped
- No subnet-wide implicit trust

The active ACL policy is managed as JSON in the Tailscale admin console (source of truth).
This repository documents the intended tagging model and enforcement structure.

See: [Tailscale ACL model](./tailscale-acl.md)

### 5.3 Governance & Change Control

- ACL changes are intentional and documented
- Service onboarding requires tag assignment and ACL review
- Binding rules (loopback or Tailscale-only) must be validated during deployment
- Security exceptions (e.g., LAN-bound services) require architectural justification

### 5.4 Least Privilege (Storage + Services)

The share model - which identity may write where, and which consumer share is scoped to which
library - is owned by [`samba.md`](samba.md), and the filesystem side of it by
[`storage-permissions.md`](storage-permissions.md). This section listed two RW shares out of the
twelve that exist until 2026-08-17; it now points instead of counting.

The principle it exists to state: read-only for consumers, read-write only for the service that
owns the data, and consistent UID/GID handling across the LXC namespace boundary so permissions do
not drift.

---

## 6. Maintenance Routines (Recommended Cadence)

### Hourly (automated)

- Nextcloud Paperless Inbox scan (`/usr/local/sbin/scan-paperless-inbox.sh` on LXC210)
  - Synchronizes Nextcloud file cache after Paperless consumes documents from External Storage mounts
  - Log: `/var/log/nextcloud-paperless-scan.log`

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

- SnapRAID scrub runs from a timer on the 1st. Review the *coverage*, not only the run date:
  `snapraid status` reports how much of the array is unscrubbed and how old the oldest block is,
  and `SnapRAIDScrubStale` can see neither - it measures when a scrub last ran
- Review disk SMART health by hand (`smartctl -A` per disk, identified by `by-id`) - the
  exported metrics cannot show degradation, see the SMART note under Planned Enhancements
- Confirm the automated restore test passed (it runs on the 1st and raises
  `PostgreSQLRestoreTestStale` if it does not). Manual spot tests are no longer the mechanism -
  this line said so until 2026-08-17

### After Major Changes

- Reboot-safe validation:
  - reboot storage -> confirm mergerfs + samba
  - reboot service nodes -> confirm automount + services
  - check monitoring target health after each layer

---

## 7. Future Improvements (Roadmap)

- ~~Automated SnapRAID sync + scrub schedule~~ (done: `snapraid-maintenance.sh`, Prometheus alerts)
- ~~IaC-style documentation: sanitized compose files, systemd unit snippets, ACL documentation~~
  (done; the `docker/`, `snippets/` and `docs/platform/tailscale-acl.md` trees are the result)
- SMART monitoring: extend the existing collector to the attributes that indicate degradation, and
  populate the empty `smart` rule group
- Off-site backups for the C1 datasets defined in [`data-classification.md`](data-classification.md)

This list is a summary. The ordered version, with the dependencies that decide what can start
when, is the [remediation plan](remediation-plan.md) - which is the document to update when
something moves.


See: [docs/platform/tailscale-acl.md](./tailscale-acl.md)
