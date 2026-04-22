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

- Unprivileged Debian LXC (CT260)
- Local block storage only (no CIFS/SMB for runtime data)
- PostgreSQL data directory: `/var/lib/postgresql/<version>/main`
- No bind-mounts from network storage

Recommended deployment:

- Dedicated infrastructure LXC
- Platform range: **CT260**
- No co-location with application services

PostgreSQL is treated as shared platform infrastructure,
not an application-local dependency.

---

## Access Model (Zero Trust)

Database access is enforced through multiple independent control layers.

No single mechanism is trusted alone.

---

### Layer 1 — Network Identity (Tailscale ACL)

Access to PostgreSQL is restricted at the overlay network level.

Only explicitly tagged services may establish TCP connections.

Example policy concept:

    tag:ai-stack  →  tag:database

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

### Layer 2 — Network Binding

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

### Layer 3 — Host-Based Authentication (pg_hba.conf)

PostgreSQL enforces an additional allowlist at the database layer via `pg_hba.conf`.
This is **independent** from Tailscale ACL (Layer 1) and binding (Layer 2).

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

### Layer 4 — Database Authorization

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

Run on CT260 as the `postgres` user unless noted.

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

**4. Update Tailscale ACL policy** — verify the service's tag has `tag:database:5432` in the
relevant ACL rule, or add one. See [tailscale-acl.md](../platform/tailscale-acl.md).

**5. Register the tenant** — add a row to the Tenant Registry table below.


### Tenant Registry

| Service | Database | User | ACL Rule | pg_hba Entry | Status |
|---|---|---|---|---|---|
| OpenWebUI (CT230) | openwebui_db | openwebui_user | tag:ai-stack → tag:database:5432 | hostssl entry, CT230 /32 | active |
| Paperless-ngx (CT211) | paperless_db | paperless_user | tag:tier1 → tag:database:5432 | hostssl entry, CT211 /32 | active |
| Vaultwarden (LXC240) | vaultwarden_db | vaultwarden_user | TBD | TBD | planned (migration from SQLite/CIFS; see KE-5) |

## Monitoring

PostgreSQL is monitored via:

- Node-level metrics (CPU, RAM, disk) — node_exporter on CT260, scraped by Prometheus on CT200
- `postgres_exporter` (prometheus-community) — runs on CT260 as a systemd service, binds to `<tailscale-ip-lxc260>:9187`, scraped by Prometheus on CT200

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
- Schedule: daily at 03:00 via crontab (`postgres` user)
- Compression: gzip
- Target: `/mnt/backups/` (SMB mount on MergerFS, separate failure domain)
- Retention: 7 days (automatic cleanup via `find -mtime`)
- Script: `/usr/local/sbin/pg-backup.sh` on CT260
- Source of truth (repo): `snippets/postgres/pg-backup.sh`

### Operational Notes

- Script runs as `postgres` user (peer authentication, no password required)
- Script ownership: `root:postgres` (mode 750)
- Pre-flight check: verifies backup directory exists before writing
- Post-dump check: verifies dump file is non-empty
- Crontab entry: `0 3 * * * /usr/local/sbin/pg-backup.sh`

### Verification

    crontab -u postgres -l
    ls -la /mnt/backups/
    zcat /mnt/backups/pg_dumpall_<timestamp>.sql.gz | head -20

### Important Distinction

Runtime database storage → local block storage (Aux1TB)
Database backups → SMB allowed (MergerFS, separate failure domain)

### Planned Improvements

- Restore test runbook (periodic validation)
- Per-database `pg_dump` once multiple consumers exist
- Backup monitoring integration (alert on missing/stale dumps)

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
          ↓
    Tailscale-only bind
          ↓
    pg_hba.conf allowlist
          ↓
    PostgreSQL role permissions

Zero Trust = multiple independent enforcement layers.

## Related Documents

- [LXC260 Node](../nodes/lxc260.md)
- [PostgreSQL Backup Runbook](../../runbooks/database/pg-backup.md)
- [PostgreSQL Restore Runbook](../../runbooks/database/pg-restore.md)
- [Tailscale ACL](../platform/tailscale-acl.md)
