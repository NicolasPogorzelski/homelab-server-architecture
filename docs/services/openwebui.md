# OpenWebUI (CT230) - Service Documentation

## Purpose

OpenWebUI is the central UI for the AI stack. It provides a chat interface
for local LLM inference and serves as the future entrypoint for RAG and
agentic workflows.

- Access is Tailscale-only (no LAN, no public ingress)
- Two inference backends: `llama-server` on the admin desktop (primary) and vm100 (fallback)
- PostgreSQL platform service (lxc260) as database backend
- Hard rule: no database files on CIFS/SMB

---

## Runtime Characteristics

- Unprivileged Debian LXC (CT230)
- Docker Compose at `/opt/openwebui/`
- `.env` at `/opt/openwebui/.env` (chmod 600, gitignored)
- Version: OpenWebUI v0.9.6 (read from `/api/version` on 2026-08-17; the entry said v0.8.10 until
  then). Note the running container uses the floating tag `ghcr.io/open-webui/open-webui:main`,
  not the pinned reference in `docker/openwebui/docker-compose.yml` - the version is stable only
  because the standing `docker-compose-update` hold means nothing has pulled since 2026-06-11.

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
- PostgreSQL (platform service, lxc260) is used instead.
- No database (SQLite or PostgreSQL data directory) may reside on CIFS/SMB
  or automount-backed network shares.

---

## Storage

| Data type | Location | Mount |
|---|---|---|
| DB (PostgreSQL) | lxc260 (local block FS) | Tailnet TCP |
| App state / config | aux-disk | `mp1: /mnt/aux-disk/openwebui -> /var/lib/openwebui/data` |
| Docker engine (containerd, volumes) | aux-disk | `mp1: /var/lib/openwebui/containerd` + `docker-data` |
| Uploads | aux-disk | `/var/lib/openwebui/data/uploads`, inside the container's only bind mount |
| Vector store | aux-disk | `/var/lib/openwebui/data/vector_db` |
| (unused) | MergerFS/SMB | `mp0: /mnt/smb/openwebui -> /data/openwebui` |

The Compose file binds `/var/lib/openwebui/data` and nothing else, so uploads and the vector store
live on the aux-disk with the rest of the app state. Measured 2026-09-29: 6.0 M of uploads and
188 K of vector store there, while `/data/openwebui` holds only empty directories and a test file
from February. The share is mounted into the container's LXC but reaches no process in it. The
database dumps are taken on lxc260 ([PostgreSQL platform service](./postgresql-platform.md)).

### Proxmox Host Paths

- SMB mount (autofs): `/mnt/smb/openwebui`
- Local block storage: `/mnt/aux-disk/openwebui`

---

## Inference Backends

OpenWebUI reaches two `llama-server` instances through its OpenAI API connections, each with its
own API key. Admin Panel -> Settings -> Connections -> OpenAI API.

| Node | URL | Model | Role |
|---|---|---|---|
| admin desktop | `http://bazzite.<tailnet-id>.ts.net:8080/v1` | `qwen3.8-27b` | Primary |
| vm100 | `http://gpu-vm.<tailnet-id>.ts.net:8080/v1` | `qwen3.5-9b` | Fallback |

Until the switch, the Ollama API connection holds the list measured on 2026-09-26:
`host.docker.internal:11434` (lxc230 itself, where nothing listens), vm100's native Ollama, and an
address the admin desktop held before its reinstallation. The primary has been unreachable since
that reinstallation, and vm100 answered every request. The switch removes all three
([rollout state](./llm-inference.md#rollout-state)).

See: [LLM Inference](./llm-inference.md)

---

## Dependencies (reboot-safe)

OpenWebUI is only healthy if all dependencies are satisfied:

1. **SMB path mounted** on Proxmox host
   - Runbook: [SMB autofs trigger](../../runbooks/storage/smb-autofs-trigger.md)
2. **aux-disk path exists** for local runtime state (`mp1`)
3. **PostgreSQL reachable** on Tailnet (lxc260)
   - See: [PostgreSQL platform service](./postgresql-platform.md)
4. **An inference backend reachable** on the tailnet (vm100 always, the admin desktop while it is on, port 8080)
   - See: [LLM Inference](./llm-inference.md)

---

## Access Model (Zero Trust)

- No public ingress (no router port-forwarding, no public reverse proxy)
- No LAN exposure - Tailscale-only
- Service binds to loopback (`127.0.0.1:3000`)
- Exposed via Tailscale Serve (`https=443 -> 3000`)
- URL: `https://ai-openwebui.<tailnet-id>.ts.net`
- Network policy enforced via Tailscale ACL (node tags + ACL JSON)
- See: [Tailscale ACL model](../platform/tailscale-acl.md)

---

## Failure Impact

If CT230 (OpenWebUI) becomes unavailable:
- AI chat interface unavailable for all users
- Inference backends (vm100, admin desktop) are unaffected
- PostgreSQL platform (lxc260) is unaffected
- No data loss (database on lxc260, uploads and vector store on the aux-disk)
- Recovery: restart LXC230, verify all dependencies (PostgreSQL reachable, SMB mounted, aux-disk present)

## Related Documents

- [LLM Inference](./llm-inference.md)
- [PostgreSQL Platform](./postgresql-platform.md)
- [Tailscale ACL](../platform/tailscale-acl.md)
- [Loopback + Tailscale Serve](../decisions/loopback-tailscale-serve.md)
