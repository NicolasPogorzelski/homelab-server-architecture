# OpenWebUI (CT230) — Service Documentation

## Purpose

OpenWebUI is the central UI for the AI stack. It provides a chat interface
for local LLM inference and serves as the future entrypoint for RAG and
agentic workflows.

- Access is Tailscale-only (no LAN, no public ingress)
- Two inference backends operational (Gaming PC + VM100)
- PostgreSQL platform service (CT260) as database backend
- Hard rule: no database files on CIFS/SMB

---

## Runtime Characteristics

- Unprivileged Debian LXC (CT230)
- Docker Compose at `/opt/openwebui/`
- `.env` at `/opt/openwebui/.env` (chmod 600, gitignored)
- Version: OpenWebUI v0.8.10

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
- PostgreSQL (platform service, CT260) is used instead.
- No database (SQLite or PostgreSQL data directory) may reside on CIFS/SMB
  or automount-backed network shares.

---

## Storage

| Data type | Location | Mount |
|---|---|---|
| DB (PostgreSQL) | CT260 (local block FS) | Tailnet TCP |
| App state / config | Aux1TB | `mp1: /mnt/aux1TB/openwebui → /var/lib/openwebui` |
| Uploads | MergerFS/SMB | `mp0: /mnt/smb/openwebui → /data/openwebui` |
| Vector store | MergerFS/SMB | `/data/openwebui/vector` (file-based only) |
| DB backups | MergerFS/SMB | `/data/openwebui/backups` |

### Proxmox Host Paths

- SMB mount (autofs): `/mnt/smb/openwebui`
- Local block storage: `/mnt/aux1TB/openwebui`

---

## Inference Backends

OpenWebUI connects to Ollama inference backends via Tailnet.

| Node | URL | Models | Role |
|---|---|---|---|
| Gaming PC | `http://<tailscale-ip-gaming-pc>:11434` | `qwen3-32b-8k`, `qwen3-14b-64k`, `qwen3-8b-128k` | Primary |
| VM100 | `http://<tailscale-ip-vm100>:11434` | `qwen3-8b-16k` | Backup |

Backend URLs are configured in OpenWebUI Admin Panel → Settings → Connections → Ollama API.

See: [Ollama Service](./ollama.md)

---

## Dependencies (reboot-safe)

OpenWebUI is only healthy if all dependencies are satisfied:

1. **SMB path mounted** on Proxmox host
   - Runbook: [SMB autofs trigger](../../runbooks/storage/smb-autofs-trigger.md)
2. **Aux1TB path exists** for local runtime state (`mp1`)
3. **PostgreSQL reachable** on Tailnet (CT260)
   - See: [PostgreSQL platform service](./postgresql-platform.md)
4. **Ollama reachable** on Tailnet (Gaming PC + VM100, port 11434)
   - See: [Ollama Service](./ollama.md)

---

## Access Model (Zero Trust)

- No public ingress (no router port-forwarding, no public reverse proxy)
- No LAN exposure — Tailscale-only
- Service binds to loopback (`127.0.0.1:3000`)
- Exposed via Tailscale Serve (`https=443 → 3000`)
- URL: `https://ai-openwebui.<tailnet-id>.ts.net`
- Network policy enforced via Tailscale ACL (node tags + ACL JSON)
- See: [Tailscale ACL model](../platform/tailscale-acl.md)

---

## Related Documents

- [Ollama Service](./ollama.md)
- [PostgreSQL Platform](./postgresql-platform.md)
- [Tailscale ACL](../platform/tailscale-acl.md)
- [Loopback + Tailscale Serve](../decisions/loopback-tailscale-serve.md)
