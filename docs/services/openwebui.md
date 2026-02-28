# OpenWebUI (CT230) — Service Documentation

## Goal
- OpenWebUI is the central UI for the AI stack.
- Access is **Tailscale-only** (no LAN, no public ingress).
- Two inference backends are planned (Gaming PC + VM100).
- Persistent memory / vector store is required.
- Professional storage separation (no “quick & dirty”).
- Hard rule: **no database files on CIFS/SMB**.

---

## Placement (CT230)

### Runtime Characteristics
- Unprivileged Debian LXC (CT230)
- Service container only (UI + app runtime)
- No co-location with databases (PostgreSQL is a separate platform service)
- Data paths are mounted explicitly (deterministic and reboot-safe)

### Why a dedicated LXC
- Clear isolation boundary (service vs. platform DB)
- Easier operational ownership (logs/config are scoped)
- Security model stays consistent with the tiered platform design

---

## Architectural Incident: SQLite on CIFS/SMB (Historical)

During initial testing, OpenWebUI used its default SQLite database
stored on a CIFS/SMB mount.

**Observed symptom:**  
`peewee.OperationalError: database is locked`

**Root cause:**  
SQLite locking semantics are not reliable on CIFS/SMB network filesystems.

**Architectural decision:**  
- SQLite was removed.
- PostgreSQL (platform service, CT250) is used instead.
- No database (SQLite or PostgreSQL data directory) may reside on CIFS/SMB or automount-backed network shares.

---

## Storage Strategy (target)

| Data type | Critical | Location | Notes |
|---|---:|---|---|
| DB (PostgreSQL) | Yes | Local block FS (ext4/xfs/zfs) | Runs in **CT250** (platform service) |
| App state / config | Medium | Local (Aux1TB) | Stable, fast, reboot-safe |
| Logs | Low | Local (Aux1TB) | Avoids network noise |
| Uploads | Yes | MergerFS/SMB | Large payloads, acceptable on SMB |
| Vector store | Yes | MergerFS/SMB (with constraints) | Only if it is **file-based**. If the vector store uses DB-like locking semantics, it must move to local block storage or Postgres (pgvector). |
| DB backups | Yes | MergerFS/SMB | Backups are allowed on SMB |

---

## Paths (Truth Sources)

### Proxmox Host
- SMB mount (autofs): `/mnt/smb/openwebui`
- Local block storage: `/mnt/aux1TB/openwebui`

### CT230 (ai-openwebui)
- SMB via bind mount: `mp0: /mnt/smb/openwebui -> /data/openwebui`
- Local via bind mount (planned): `mp1: /mnt/aux1TB/openwebui -> /var/lib/openwebui`

---

## Planned Volume Layout (CT230)

- App data: `/var/lib/openwebui/appdata` (Aux1TB)
- Logs: `/var/lib/openwebui/logs` (Aux1TB)
- Uploads: `/data/openwebui/uploads` (SMB)
- Vector: `/data/openwebui/vector` (SMB)
- Backups: `/data/openwebui/backups` (SMB)

---

## Dependencies (reboot-safe requirements)

OpenWebUI must only be considered “healthy” if all dependencies are satisfied:

1. **SMB path exists and is mounted** on the Proxmox host  
   - Runbook: [SMB autofs trigger](../../runbooks/storage/smb-autofs-trigger.md)
2. **Aux1TB path exists** for local runtime state (`mp1`)  
   - This prevents DB-like state from living on SMB.
3. **PostgreSQL platform service is reachable on Tailnet** (CT250)  
   - See: [PostgreSQL platform service](./postgresql-platform.md)

---

## Database Dependency

OpenWebUI relies on a centralized PostgreSQL platform service
running in a dedicated PostgreSQL platform LXC (**CT250**).

Database access is **Tailnet-only**.

See: [PostgreSQL platform service](./postgresql-platform.md)

---

## Access Model (Zero Trust)

### Exposure
- No public ingress (no router port-forwarding, no public reverse proxy).
- No LAN exposure for this service (Tailscale-only).

### Network Enforcement
- Network policy is enforced via **Tailscale ACL** (node tags + ACL JSON).
- See: [Tailscale ACL model](../platform/tailscale-acl.md)

### Binding Rule
Preferred patterns (choose one per deployment):
- Bind service to **loopback** and publish via **Tailscale Serve** (service never listens on LAN), or
- Bind service directly to the **Tailscale IP** only (no LAN bind)

(Exact choice is documented in the runtime deployment/runbook once implemented.)
