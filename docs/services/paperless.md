# Paperless-ngx (CT211) — Service Documentation

## Purpose

Paperless-ngx is a self-hosted document management system with automatic OCR,
classification, tagging, and full-text search.

- Access is Tailscale-only (no LAN, no public ingress)
- PostgreSQL platform service (CT260) as database backend
- Redis as task queue, cache, and locking backend
- Gotenberg + Apache Tika for document conversion and content extraction
- Hard rule: no database files on CIFS/SMB

---

## Runtime Characteristics

- Unprivileged Debian LXC (CT211)
- Docker Compose at `/opt/paperless/`
- `.env` at `/opt/paperless/.env` (chmod 600, gitignored)
- Compose file: symlinked from `/opt/homelab-server-architecture/docker/paperless/docker-compose.yml`

---

## Storage

| Data type | Location | Mount |
|---|---|---|
| DB (PostgreSQL) | CT260 (local block FS) | Tailnet TCP |
| Documents (originals, archive) | MergerFS/SMB | `mp0: /mnt/smb/paperless → /data/paperless` |
| Thumbnails | MergerFS/SMB | `/data/paperless/thumbnails` |
| Consumption inbox | MergerFS/SMB | `/data/paperless/consumption` |
| Export | MergerFS/SMB | `/data/paperless/export` |
| App data | Docker volume | `paperless-data` |
| Logs | Aux1TB | `mp1: /var/lib/paperless/logs` |

### Proxmox Host Paths

- SMB mount (autofs): `/mnt/smb/paperless`
- Local block storage: `/mnt/aux1TB/paperless`

---

## Container Stack

| Container | Image | Role |
|---|---|---|
| paperless | `ghcr.io/paperless-ngx/paperless-ngx:latest` | Web UI + API + Celery workers |
| paperless-redis | `redis:7-alpine` | Task queue, cache, locking |
| paperless-gotenberg | `gotenberg/gotenberg:8` | Document conversion (Office → PDF) |
| paperless-tika | `apache/tika:latest` | Content extraction (metadata, text) |

All containers run in Docker bridge network. Inter-container communication
uses Docker DNS (container names).

---

## Database Dependency

Paperless-ngx uses the centralized PostgreSQL platform service (CT260).

- Database: `paperless_db`
- User: `paperless_user`
- Connection: Tailscale IP of CT260, port 5432 (TLS required)
- pg_hba: `hostssl` entry scoped to CT211 Tailscale IP `/32`

See: [PostgreSQL Platform Service](./postgresql-platform.md)

---

## Dependencies (reboot-safe)

Paperless-ngx is only healthy if all dependencies are satisfied:

1. **SMB path mounted** on Proxmox host
   - Runbook: [SMB autofs trigger](../../runbooks/storage/smb-autofs-trigger.md)
2. **Aux1TB path exists** for local runtime state (`mp1`)
3. **PostgreSQL reachable** on Tailnet (CT260)
   - See: [PostgreSQL platform service](./postgresql-platform.md)

---

## Access Model (Zero Trust)

- No public ingress (no router port-forwarding, no public reverse proxy)
- No LAN exposure — Tailscale-only
- Service binds to loopback (`127.0.0.1:8000`)
- Exposed via Tailscale Serve (`https=443 → 8000`)
- URL: `https://paperless.<tailnet-id>.ts.net`
- Network policy enforced via Tailscale ACL (node tags + ACL JSON)
- See: [Tailscale ACL model](../platform/tailscale-acl.md)

### Environment Configuration (Security-Relevant)

| Variable | Purpose |
|---|---|
| `PAPERLESS_URL` | Base URL for the application. Required for correct link generation, API responses, and CSRF validation. Set to the Tailscale Serve hostname. |
| `PAPERLESS_CSRF_TRUSTED_ORIGINS` | Django CSRF origin allowlist. Must include the Tailscale Serve URL. Without this, POST requests from browsers and mobile clients are rejected (HTTP 403). |

Both values must match the Tailscale Serve URL (`https://paperless.<tailnet-id>.ts.net`).

### Client Access

- Browser: via Tailscale Serve URL (HTTPS)
- Mobile: Paperless Mobile (Android) — connects to the same Tailscale Serve URL
- Both require the device to be authenticated on the Tailnet

---

## Failure Impact

If LXC211 becomes unavailable:

- No document ingestion, search, or management
- Document files on SMB storage remain intact
- PostgreSQL data (metadata, tags, classifications) remains intact in CT260
- Recovery: recreate LXC, redeploy Docker stack, remount storage, verify DB connectivity

If PostgreSQL (CT260) becomes unavailable:

- Paperless cannot start or process documents
- Document files on SMB remain intact
- Recovery: restore CT260 first, then restart Paperless containers

---

## Related Documents

- [Node Documentation: LXC211](../nodes/lxc211.md)
- [PostgreSQL Platform](./postgresql-platform.md)
- [Tailscale ACL](../platform/tailscale-acl.md)
- [Loopback + Tailscale Serve](../decisions/loopback-tailscale-serve.md)
