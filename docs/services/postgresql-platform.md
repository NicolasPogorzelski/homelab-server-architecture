# PostgreSQL Platform Service (Central Database)

## Purpose

Provide a centralized PostgreSQL platform service for multiple applications
(OpenWebUI, Immich, Paperless, Nextcloud components, future services).

Goals:

- consistent hardening
- centralized backups
- operational reproducibility
- strict tenant separation
- Zero-Trust compliant database access

---

## Container Placement

### Runtime Characteristics

- Unprivileged Debian LXC (CT250)
- Local block storage only (no CIFS/SMB for runtime data)
- PostgreSQL data directory: `/var/lib/postgresql/<version>/main`
- No bind-mounts from network storage

Recommended deployment:

- Dedicated infrastructure LXC
- Platform range: **CT250**
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

    tag:ai-stack  →  tag:postgres

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

For each new service:

1. create database
2. create service user
3. restrict privileges
4. add pg_hba allow entry
5. update Tailscale ACL policy

## Monitoring

PostgreSQL is monitored via:

- Node-level metrics (CPU, RAM, disk)
- Planned PostgreSQL exporter integration
- Connection count monitoring
- Replication status (future, if HA introduced)

---

## Backup Strategy

Backups are centralized:

- periodic pg_dump
- stored on MergerFS / SMB storage
- restore testing required

Important distinction:

Runtime database storage → local block storage  
Database backups → SMB allowed

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
