# Operations & Maintenance

The operational model of the platform: what is monitored, how data is protected, how the platform
comes up after a power-on, how common failures are handled, and which routines keep it healthy.
The goal is reboot-safe, least-privilege infrastructure whose recovery is written down.

See: [Runbook index](../../runbooks/README.md), [Known errors](known-errors.md)

---

## 0. System Overview (Operational View)

### Core Building Blocks

- **Proxmox host:** runs every VM and LXC, owns boot ordering and the nightly power schedule.
- **vm102 (storage):** SnapRAID + MergerFS + Samba; the single source of truth for persistent data.
- **vm100 (GPU compute):** Docker workloads for Jellyfin and Audiobookshelf, llama-server fallback
  backend, GPU passthrough.
- **Service LXCs:** lxc200 monitoring, lxc210 Nextcloud (native Apache/PHP/MariaDB/Redis), lxc211
  Paperless-ngx, lxc220 Calibre-Web, lxc230 OpenWebUI, lxc250 Ansible control node, lxc260
  PostgreSQL platform database.

Node detail lives in `docs/nodes/`; membership in `ansible/inventory/hosts.yml.example`.

### Trust Boundaries

- **Public Internet:** no exposure, no router port forwarding.
- **LAN:** no service is reachable; `lan_guard` admits only SMB to vm102 from vm100 and the
  hypervisor, and break-glass SSH and netconsole to the hypervisor.
- **Tailnet:** identity-based access for administration and use ([tailscale-acl.md](tailscale-acl.md)).
- **Storage:** segmentation at the SMB layer with separate read-write and read-only identities
  ([samba.md](samba.md)).

---

## 1. Monitoring

Prometheus, Grafana and Alertmanager run on lxc200, bind loopback and are reached through
`tailscale serve` ([lxc200.md](../nodes/lxc200.md)). Every node, lxc250 and the hypervisor
included, is scraped; the target list and every alert rule are in [monitoring.md](monitoring.md),
rendered from the inventory.

Covered layers: compute (CPU, RAM, swap), storage (filesystems, thin pool, SnapRAID sync, scrub
and coverage, SMART), systemd unit state on every node, backups (database dumps, restore tests,
guest and host-config backup), service reachability (blackbox probes), pending security updates,
listeners outside the binding rule, and configuration drift.

Open: an external heartbeat, so that a total outage produces an alert instead of silence
([monitoring.md](monitoring.md#watchdog-and-the-missing-heartbeat)).

---

## 2. Data Protection & Backup Strategy

### 2.1 SnapRAID (vm102)

SnapRAID gives parity protection to the MergerFS data disks. It is not real-time: data written
since the last sync is unprotected.

- Sync daily, scrub weekly, status daily, each a systemd timer with `Persistent=true` driving the
  template unit `snapraid-maintenance@.service`. Times and the scrub percentage are in the
  `snapraid_maintenance` role defaults.
- `SnapRAIDSyncStale`, `SnapRAIDScrubStale` (10 days without a scrub) and the coverage rules alert
  on missed or ineffective runs ([monitoring.md](monitoring.md#notes-on-specific-rules)).
- Inspect with `systemctl list-timers 'snapraid-*'` and `journalctl -u snapraid-maintenance@sync`.
- Runbooks: [snapraid-sync](../../runbooks/storage/snapraid-sync.md),
  [snapraid-scrub](../../runbooks/storage/snapraid-scrub.md).

Suited to mostly static large libraries; dynamic datasets depend on the sync cadence.

### 2.2 MergerFS (vm102)

MergerFS provides one namespace over the data disks: no redundancy, no parity, no replication. It
keeps service paths stable while disks are added or replaced ([storage-design.md](storage-design.md)).

### 2.3 Service Data

- **Nextcloud (lxc210):** user files on the archive pool via CIFS (`/mnt/nextcloud`); MariaDB local
  to the container, dumped daily to a dedicated share by `mariadb_backup` and restored monthly by
  `mariadb_restore_test` ([runbook](../../runbooks/database/mariadb-backup.md)). Files and database
  sit on different disks; restoring one without the other yields unusable data.
- **PostgreSQL platform (lxc260):** databases on local block storage on the host's aux-disk
  ([KE-13](known-errors.md#ke-13), [lxc260.md](../nodes/lxc260.md)). Daily `pg_dumpall`, verified
  at write time, stored on SMB; a monthly restore into a throwaway cluster is watched by
  `PostgreSQLRestoreTestStale`.
- **Paperless-ngx (lxc211):** documents on the archive pool via SMB, database in the PostgreSQL
  platform (covered by its dump), runtime state on local storage.
- **Machines:** daily `vzdump` of all nine guests and a daily host-config backup on the host
  (`guest_backup` role, [runbook](../../runbooks/platform/guest-backup-restore.md)); the newest of
  each goes to the Backup-Archive monthly ([runbook](../../runbooks/platform/backup-archive.md)).

### 2.4 Backup Scope & Residual Risk

Protected: single disk failure (within SnapRAID limits), database corruption (dumps plus tested
restores), loss of a guest (guest backup).

Not protected:

- deletion that is synced before it is noticed;
- ransomware with write access to a read-write share;
- site loss: no off-site copy exists. The `offsite_backup` role (restic to an append-only
  `rest-server`) and its [runbook](../../runbooks/backup/offsite-backup.md) are built; the target
  VPS is not provisioned and the role is not deployed. This is the first item of the
  [remediation plan](remediation-plan.md).

---

## 3. Startup & Dependency Modeling

### 3.1 Dependency Layers (Boot Order)

**Layer 0: Hypervisor** - Proxmox up, networking and Tailscale up.

**Layer 1: Storage** - vm102 online, data and parity disks mounted, MergerFS at `/mnt/mergerfs`,
Samba reachable.

**Layer 2: Compute** - vm100 online; media libraries under `/srv/media/*` through one systemd
automount per library.

**Layer 3: Services** - LXCs 200, 210, 211, 220, 230, 250, 260 online; each service has its mounts
before critical workloads start; Docker containers use `restart: unless-stopped`, and
`docker_boot_retry` restarts containers whose first start failed.

**Layer 4: Validation** - monitoring confirms every target is up; spot-check endpoints over
loopback or the tailnet.

The startup order and delays are set on the host ([proxmox-host.md](proxmox-host.md)).

### 3.2 Mount Strategy

- Storage VM: `/etc/fstab` (systemd-generated mount units) for ext4 and MergerFS.
- Consumers: systemd automount for CIFS, so a boot does not fail while storage is still starting.
- Docker is ordered after the `.automount` units it binds, never the `.mount` units
  ([KE-15](known-errors.md#ke-15)).
- Services mount read-only wherever they do not own the data.

### 3.3 Operational Invariant

After a power-on the platform converges without manual steps: mounts present, services running,
monitoring reporting healthy.

---

## 4. Incident Response (Common Failure Scenarios)

### 4.1 Disk Failure (SnapRAID Data Disk)

Symptoms: missing `/mnt/diskXX`, I/O errors or a read-only remount, SnapRAID reports a missing
disk.

1. Replace the disk.
2. Recreate the filesystem and mountpoint.
3. Restore the data with `snapraid fix`.
4. Verify integrity and re-sync parity.

### 4.2 Parity Disk Failure

Symptoms: `/mnt/parity` missing or unreadable.

1. Replace the parity disk.
2. Recreate the filesystem and mountpoint.
3. Rebuild parity with `snapraid sync`.
4. Run a scrub after the rebuild.

### 4.3 MergerFS Mount Failure

Symptoms: `/mnt/mergerfs` missing, services failing on missing paths.

- Confirm every underlying disk mount exists.
- Inspect the systemd mount unit generated from fstab and the journal for fuse/mergerfs errors.
- Check `allow_other` / `user_allow_other`.

### 4.4 CIFS Mount Failure in a Service LXC/VM

Symptoms: `/books`, `/mnt/nextcloud` or similar missing or empty; the service reports a missing
library or data directory; `systemctl --failed` lists a mount or automount unit.

- `findmnt -T <path>`, then the unit and its journal.
- Credentials file permissions and username.
- Samba on vm102 reachable.
- UID/GID mapping, especially in unprivileged LXCs.
- Runbook: [smb-autofs-trigger](../../runbooks/storage/smb-autofs-trigger.md).

### 4.5 Container Failure / Restart Loops

Symptoms: restarts in `docker ps`, unhealthy healthcheck, logs naming missing mounts or
permissions.

- Confirm mounts before debugging the application.
- Check container logs and UID/GID alignment.
- Confirm the intended loopback binding.

### 4.6 PostgreSQL Platform Failure

Symptoms: applications cannot connect, `pg_isready` fails, `PostgreSQLDown` or `NodeDown` for
lxc260.

1. Confirm the Tailscale interface is up and PostgreSQL bound its Tailscale address
   ([KE-9](known-errors.md#ke-9)).
2. Read the PostgreSQL log.
3. Confirm `pg_hba` is unchanged.
4. Restore from the dump if data is corrupt ([pg-restore](../../runbooks/database/pg-restore.md)).

Runtime data is on local block storage; the dumps are on SMB and survive a runtime failure.

---

## 5. Security Posture

### 5.1 Exposure Rules

- No public reverse proxy, no router port forwarding.
- Internal services bind loopback where possible; infrastructure services bind the Tailscale
  address.
- No service is reachable from the LAN; the SMB path to vm102 is the only named LAN flow.

Where a daemon cannot bind narrowly (Samba on vm102, Apache and `coolwsd` on lxc210), the
`lan_guard` table drops LAN connections before they reach the socket
([SMB bind decision](../decisions/smb-bind-and-lan-access.md)). sshd is pinned to the Tailscale
address on every guest; on the hypervisor it stays on the wildcard so LAN break-glass SSH works
([decision](../decisions/sshd-listen-address.md)). Remaining wildcard binds are tracked in the
[remediation plan](remediation-plan.md) and reported by `ListenerOutsideBindingRule`.

### 5.2 Tailnet Access

- Every remote access requires an authenticated Tailscale identity.
- Service-to-service permissions are tag-based and port-scoped; there is no subnet-wide trust.
- The Tailscale admin console is the source of truth for the policy;
  [tailscale-acl.md](tailscale-acl.md) mirrors it and changes are applied by hand.

### 5.3 Change Control

- ACL changes are made in the policy file and the console together, with tests.
- Onboarding a service requires a tag assignment and an ACL review.
- Binding rules (loopback or Tailscale only) are checked at deployment and by
  `listener_metrics` afterwards.
- A LAN-bound service needs a decision record.

### 5.4 Least Privilege (Storage + Services)

Consumers get read-only access, the owning service alone gets read-write, and UID/GID handling
is consistent across the LXC namespace boundary. The share model is in [samba.md](samba.md), the
filesystem side in [storage-permissions.md](storage-permissions.md).

---

## 6. Maintenance Routines

### Automated

Scheduled jobs are systemd timers, calendar timers with `Persistent=true`; schedules are in
each role's defaults, and the exceptions are listed in [ansible.md](ansible.md#conventions).

- Hourly: Nextcloud rescan of the Paperless inbox on lxc210 (`paperless_inbox_scan`); output in
  the journal of its service.
- Daily: database dumps, SnapRAID sync and status, host-config backup.
- Weekly: SnapRAID scrub, fleet snapshot and drift sweep.
- Monthly: PostgreSQL and MariaDB restore tests.

### Manual

- **Daily:** glance at dashboards and active alerts.
- **Weekly:** review container restarts and errors.
- **Monthly:** review SnapRAID coverage (`snapraid status`: unscrubbed share and oldest block age),
  not only the scrub date; cross-check SMART by hand (`smartctl -A` per disk by `by-id`) against
  the `smart` alert group; confirm both restore tests passed.

### After Major Changes

Reboot in layers and check monitoring after each: storage (MergerFS and Samba), then service
nodes (automounts and services).

---

## 7. Open Work

The ordered list, with dependencies, is the [remediation plan](remediation-plan.md). The largest
open items: the off-site copy of the C1 datasets ([data-classification.md](data-classification.md))
and the external heartbeat.
