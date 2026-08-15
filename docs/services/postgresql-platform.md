# PostgreSQL Platform Service (Central Database)

## Purpose

Provide a centralized PostgreSQL platform service for multiple applications
(OpenWebUI, Paperless, Nextcloud components, future services).

Goals:

- consistent hardening
- centralized backups
- operational reproducibility
- strict tenant separation
- Zero-Trust compliant database access

---

## Container Placement

### Runtime Characteristics

- Unprivileged Debian LXC (lxc260)
- Local block storage only (no CIFS/SMB for runtime data)
- PostgreSQL data directory: `/var/lib/postgresql/<version>/main`
- No bind-mounts from network storage

Recommended deployment:

- Dedicated infrastructure LXC
- Platform range: lxc260
- No co-location with application services

PostgreSQL is treated as shared platform infrastructure,
not an application-local dependency.

---

## Access Model (Zero Trust)

Database access is enforced through multiple independent control layers.

No single mechanism is trusted alone.

---

### Layer 1 - Network Identity (Tailscale ACL)

Access to PostgreSQL is restricted at the overlay network level.

Only explicitly tagged services may establish TCP connections.

Example policy concept:

    tag:ai-stack  ->  tag:database

See: [docs/platform/tailscale-acl.md](../platform/tailscale-acl.md)

Meaning:

- OpenWebUI (CT230) may connect
- other nodes cannot reach PostgreSQL

Result:

- Unauthorized nodes cannot open TCP connections
- No LAN trust
- No router exposure
- Identity-based networking

PostgreSQL is never exposed to LAN or public networks.

---

### Layer 2 - Network Binding

PostgreSQL listens exclusively on its Tailscale interface.

Example:

    listen_addresses = 100.x.y.z

NOT allowed:

- 0.0.0.0
- LAN interface binding
- bridge interfaces

Result:

Even LAN compromise cannot reach PostgreSQL.

---

### Layer 3 - Host-Based Authentication (pg_hba.conf)

PostgreSQL enforces an additional allowlist at the database layer via `pg_hba.conf`.
This is independent from Tailscale ACL (Layer 1) and binding (Layer 2).

Key goals:
- require TLS (`hostssl`)
- restrict by (DB, user) tuple
- restrict by client identity (single tailnet node `/32`)
- require strong password auth (`scram-sha-256`)
- optional later: require client certificates (mTLS)

Example (minimal, per-service allowlist):

    # 1) Always allow local admin / maintenance on the DB node itself
    local   all             postgres                                peer

    # 2) Service allowlist (TLS required + per-service DB/user + /32 client)
    hostssl openwebui_db    openwebui_user   100.x.y.z/32           scram-sha-256

    # 3) Default deny (everything else)
    host    all             all             0.0.0.0/0              reject
    host    all             all             ::/0                    reject

Meaning:
- Only the OpenWebUI service user may access `openwebui_db`.
- Only from the approved client node (single Tailscale IP `/32`).
- Only over TLS (`hostssl`).
- Authentication must use SCRAM.

Result:
- Even if another node can reach the port (misconfig / future change), it still cannot authenticate.
- Blast radius is reduced to explicitly allowed service identities.
- Explicit deny prevents accidental broad access if defaults change.

Optional hardening (later):
- enforce client certificates (mTLS):

    hostssl openwebui_db    openwebui_user   100.x.y.z/32           scram-sha-256 clientcert=verify-full

(Use mTLS only when you are ready to manage client cert lifecycle operationally.)

---

### Layer 4 - Database Authorization

Each service receives:

- dedicated database
- dedicated user
- minimal privileges

Example:

    OpenWebUI
      ├── DB: openwebui_db
      └── User: openwebui_user

No shared credentials exist.

---

## Operational Model

### Service Onboarding Pattern

Steps 1-3 are codified in the `postgresql_provisioning` Ansible role
(`ansible/playbooks/postgresql-provisioning.yml`): add the tenant to
`postgres_tenants` in `host_vars/lxc260.yml` (non-secret fields) and its password
to `postgres_tenant_passwords` (Vault-referenced), then run the playbook. The role
is idempotent and connects via peer auth as the `postgres` user. The manual SQL
below is the reference the role implements; steps 4-5 remain manual.

Run on lxc260 as the `postgres` user unless noted.

**1. Create database and user**
```sql
CREATE DATABASE <service>_db;
CREATE USER <service>_user WITH PASSWORD '<strong-password>';
GRANT ALL PRIVILEGES ON DATABASE <service>_db TO <service>_user;
\c <service>_db
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT ALL ON SCHEMA public TO <service>_user;
```

**2. Add pg_hba.conf entry** (`/etc/postgresql/<version>/main/pg_hba.conf`):
```
hostssl <service>_db    <service>_user    <tailscale-ip-lxc###>/32    scram-sha-256
```

**3. Reload PostgreSQL**
```bash
systemctl reload postgresql
```

**4. Update Tailscale ACL policy** - verify the service's tag has `tag:database:5432` in the
relevant ACL rule, or add one. See [tailscale-acl.md](../platform/tailscale-acl.md).

**5. Register the tenant** - add a row to the Tenant Registry table below.


### Tenant Registry

| Service | Database | User | ACL Rule | pg_hba Entry | Status |
|---|---|---|---|---|---|
| OpenWebUI (CT230) | openwebui_db | openwebui_user | tag:ai-stack -> tag:database:5432 | hostssl entry, CT230 /32 | active |
| Paperless-ngx (CT211) | paperless_db | paperless_user | tag:tier1 -> tag:database:5432 | hostssl entry, CT211 /32 | active |
| Vaultwarden (LXC240) | vaultwarden_db | vaultwarden_user | TBD | TBD | planned (migration from SQLite/CIFS; see KE-5) |

## Monitoring

PostgreSQL is monitored via:

- Node-level metrics (CPU, RAM, disk) - node_exporter on lxc260, scraped by Prometheus on CT200
- `postgres_exporter` (prometheus-community) - runs on lxc260 as a systemd service, binds to `<tailscale-ip-lxc260>:9187`, scraped by Prometheus on CT200

**Monitoring user:** `postgres_exporter` with `pg_monitor` role (read-only access to all `pg_stat_*` views).

**Active alert rules** (`docker/monitoring/prometheus/rules/alert.rules.yml`):

| Alert | Condition | Severity |
|---|---|---|
| `PostgreSQLDown` | `pg_up == 0` for >2m | critical |
| `PostgreSQLConnectionsHigh` | active connections >80% of `max_connections` for >5m | warning |

- Replication status: future, if HA introduced

---

## Backup Strategy

### Implementation

- Tool: `pg_dumpall` (all databases + global objects / roles)
- Schedule: `pg-backup.timer` - `OnCalendar=*-*-* 03:00:00`, `Persistent=true`
- Compression: gzip
- Target: `/mnt/backups/` (SMB mount on MergerFS, separate failure domain)
- Retention: 7 days nominal, 8 in practice - `find -mtime +7` truncates age to whole 24-hour
  units and `+7` requires strictly greater, so a dump is removed only once it passes 8 days
  (observed 2026-08-14: the 2026-08-07 dump survived at 7 d 5 h). Covers `*.sql.gz` and
  `*.sql.gz.partial`
- Script: `/usr/local/sbin/pg-backup.sh` on lxc260
- Source of truth (repo): `snippets/postgres/pg-backup.sh`
- Managed by: `ansible/roles/postgresql_backup/`

### Operational Notes

- Service runs as `postgres` user (`User=postgres` in the unit; peer authentication, no password)
- Script ownership: `root:postgres` (mode 750)
- Pre-flight check: verifies `/mnt/backups` is a CIFS mount via `findmnt -no FSTYPE`, and
  refuses to run otherwise. Testing only that the directory exists was the bug that let 26 days
  of backups silently write nowhere useful - an empty mountpoint is a directory too.
- Post-dump checks (three, each catching a different class): the file is non-empty; `gzip -t`
  proves the compressed stream is intact; and the dump carries exactly one
  `PostgreSQL database cluster dump complete` marker. The third is the one that matters - a
  `pg_dumpall` killed halfway still produces a valid gzip member, so `gzip -t` reports
  success on a dump that restores without error into empty tables.
- The dump is written to `<name>.sql.gz.partial` and renamed only after all three checks pass.
  A plain redirect creates the file before `pg_dumpall` writes a byte, so an aborted run would
  leave a ruin under the real name - which the restore test selects as "newest dump" and a human
  would mistake for a backup during recovery. Retention covers both names, so failed runs cannot
  accumulate `.partial` files on the share.
- **Verification runs before retention deletion, and that ordering is the point.** Retention keeps
  7 days; the monthly restore test detects a bad dump up to 31 days later. The retention window is
  shorter than the detection window, so a dump checked only by the monthly test is found broken at
  a moment when every healthy predecessor has already been deleted.
- Success writes `pg_backup_last_success_timestamp` to the node_exporter textfile collector,
  which feeds the `PostgreSQLBackupStale` alert. Only reached when all three checks passed, so
  the metric means "a verified dump exists", not "the script ran".

**What the write-time checks do not prove:** that the bytes reached vm102. The read-back is served
from the CIFS page cache (`cache=strict`), so this establishes that the stream is complete and
self-consistent, not that it is durable on the far side. Durability is what the monthly restore
test covers - it reads a dump the cache has long since forgotten.

Scheduled via a systemd timer, not cron. The Proxmox host powers down before 03:00 every night,
so the cron entry never fired: backups had not run for 26 days when this was found on 2026-07-10.
`Persistent=true` runs the overdue dump at the next boot, and a failed run raises
`SystemdUnitFailed`.

**Blind spot of `PostgreSQLBackupStale` (measured 2026-08-14).** The rule fires after 25 hours,
but it cannot see an outage in which the host is off, because Prometheus runs on that same host.
Measured over the seven days to 2026-08-14, the `up{job="node-lxc260-postgres"}` series holds 48
of 169 hourly points, with a 62-hour gap from Mon 2026-08-10 21:50 to Thu 2026-08-13 11:50 - and
`ALERTS{alertname="PostgreSQLBackupStale"}` is empty across the whole range. Nothing observed the
gap: while the host was down there was no scrape, and by the time Prometheus came back the
`Persistent=true` catch-up had already refreshed the timestamp. The dumps confirm it - 2026-08-07,
09, 10, 13, 14, none of them at 03:00, all at boot time (05:32 to 08:53).

So the rule means "not more than 25 hours of uptime without a backup", not "a backup every
day". Three days can pass with no dump and nothing turns red. This is not worth
"fixing" with an alert - on a host that powers down nightly by design, an alert for "the host was
off" is pure noise - but the 25-hour figure promises daily coverage it does not deliver, and that
is what makes it worth writing down. Same class as the host `node_exporter` whose failure
concealed itself ([KE-18](../platform/known-errors.md#ke-18)): a guard that shares a failure
domain with the thing it guards. A second consequence: retention is *7 days*, not *7 dumps* -
days without a boot produce no dump, and the share currently holds five.

### Verification

    systemctl list-timers pg-backup.timer
    journalctl -u pg-backup.service -n 30
    ls -la /mnt/backups/
    zcat /mnt/backups/pg_dumpall_<timestamp>.sql.gz | head -20

### Important Distinction

Runtime database storage -> local block storage (aux-disk)
Database backups -> SMB allowed (MergerFS, separate failure domain)

### Planned Improvements

- ~~Restore test runbook (periodic validation)~~ done 2026-08-13 - `runbooks/database/pg-restore.md`
  executed and recorded, then automated as the `postgresql_restore_test` role (monthly,
  `PostgreSQLRestoreTestStale` at 40 days)
- ~~Backup monitoring integration (alert on missing/stale dumps)~~ done - `PostgreSQLBackupStale`,
  with the blind spot documented above
- Per-database `pg_dump` once multiple consumers exist
- **Off-site copy.** Still the largest remaining gap: every dump lives on vm102, on the same site,
  in the same rack. Write-time verification proves a dump is readable; it does not survive site
  loss or ransomware.

---

## Durability Stance

- fsync = on
- synchronous_commit = on
- Full ACID compliance is preserved.

Performance optimizations must not weaken data integrity guarantees.

---

## Failure Domain Consideration

Central PostgreSQL introduces a shared dependency.

Mitigations:

- automated backups
- restore runbooks
- documented recovery procedures
- deterministic deployment

Failure Impact:

- All dependent services lose database connectivity.
- Application startup may fail.
- Existing connections are terminated.
- No data loss if WAL and fsync guarantees are intact.

Recovery priority: restore database service before application restart.

---

## Architectural Rationale

Centralized PostgreSQL platforms reduce:

- patch drift
- backup inconsistency
- monitoring fragmentation
- credential sprawl

Dedicated DB instances are used only when isolation
or SLO requirements demand it.

---

## Security Summary

Access requires passing ALL layers:

    Tailscale ACL
          v
    Tailscale-only bind
          v
    pg_hba.conf allowlist
          v
    PostgreSQL role permissions

Zero Trust = multiple independent enforcement layers.

## Failure Impact

If lxc260 (PostgreSQL) becomes unavailable:
- All dependent services lose database connectivity: OpenWebUI (CT230), Paperless-ngx (CT211)
- Application startup fails for DB-dependent services
- Existing connections are terminated immediately
- No data loss if WAL and fsync guarantees were intact before failure
- Recovery priority: restore lxc260 before restarting application containers

## Related Documents

- [LXC260 Node](../nodes/lxc260.md)
- [PostgreSQL Backup Runbook](../../runbooks/database/pg-backup.md)
- [PostgreSQL Restore Runbook](../../runbooks/database/pg-restore.md)
- [Tailscale ACL](../platform/tailscale-acl.md)
