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

Recommended deployment:

- Dedicated infrastructure LXC
- Platform range: **CT250**
- No co-location with application services

PostgreSQL is treated as shared platform infrastructure,
not an application-local dependency.

---

## Zero-Trust Access Model

Database access is enforced through multiple independent control layers.

No single mechanism is trusted alone.

---

### Layer 1 — Network Identity (Tailscale ACL)

Access to PostgreSQL is restricted at the overlay network level.

Only explicitly tagged services may establish TCP connections.

Example policy concept:

    tag:ai-stack  →  tag:postgres

See: docs/platform/tailscale-acl.md

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

PostgreSQL performs an additional allowlist verification.

Example:

    hostssl openwebui_db openwebui_user 100.x.y.z/32 scram-sha-256

Meaning:

- TLS required
- specific database
- specific service user
- single approved client node

Result:

- Only approved service nodes authenticate
- Lateral movement reduced
- Blast radius minimized

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

## Failure Domain Consideration

Central PostgreSQL introduces a shared dependency.

Mitigations:

- automated backups
- restore runbooks
- documented recovery procedures
- deterministic deployment

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
