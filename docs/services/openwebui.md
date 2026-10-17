# OpenWebUI

Chat front end of the AI stack on lxc230. It stores its state in PostgreSQL on lxc260 and sends
inference to two `llama-server` backends. Node details: [lxc230](../nodes/lxc230.md).

## Deployment

- Compose stack in `/opt/openwebui`, source `docker/openwebui/docker-compose.yml` (image version
  there), synced by `docker_compose_update`
- `.env` in `/opt/openwebui` (mode 600, never committed) holds `DATABASE_URL` and
  `WEBUI_SECRET_KEY`; template `docker/openwebui/.env.example`
- Releases since 0.10 migrate the database with no downgrade. A rollback is a restore of
  `openwebui_db` from a dump taken before the image change, together with the previous pin.

## Storage

| Data | Location |
|---|---|
| Database | `openwebui_db` on lxc260, SCRAM over TLS ([PostgreSQL platform](./postgresql-platform.md)) |
| App state, `uploads/`, `vector_db/` | `/var/lib/openwebui/data`, the Compose file's only bind mount |
| Docker engine state | `/var/lib/openwebui/containerd`, `/var/lib/openwebui/docker-data` |

`/var/lib/openwebui` is `mp1`, `/mnt/aux-disk/openwebui` on the host's aux-disk
([KE-13](../platform/known-errors.md#ke-13)). The container has no SMB mount. SQLite on CIFS failed
with `database is locked` in testing ([KE-1](../platform/known-errors.md#ke-1)), so no database file
may sit on a network share.

## Inference Backends

Configured under Admin Panel -> Settings -> Connections -> OpenAI API, one API key per backend:

| Node | URL | Role |
|---|---|---|
| admin desktop | `http://bazzite.<tailnet-id>.ts.net:8080/v1` | primary, while the desktop is on |
| vm100 | `http://gpu-vm.<tailnet-id>.ts.net:8080/v1` | fallback, always on |

The Ollama API connection is off and holds no URL; Direct Connections are off, so users cannot add
endpoints; the model list cache is off, so the list follows whether the desktop is running. Models
and measurements: [LLM inference](./llm-inference.md).

## Dependencies

1. aux-disk path present on the host (`mp1`)
2. PostgreSQL on lxc260 reachable over the tailnet
3. At least one backend reachable on port 8080: vm100 always, the desktop while it is on

## Access Model

- OpenWebUI binds `127.0.0.1:3000` and is published through `tailscale serve` on 443:
  `https://ai-openwebui.<tailnet-id>.ts.net` ([decision](../decisions/loopback-tailscale-serve.md)).
- No LAN or public path; `lan_guard` drops new inbound LAN connections on lxc230.
- Grants: admin workstations, admin phone and the monitoring probe reach 443; `tag:ai-stack`
  reaches `tag:database:5432` and both backends on 8080
  ([tailscale-acl.md](../platform/tailscale-acl.md)).

## Failure Impact

- No chat interface. Backends and lxc260 are unaffected; no other service depends on OpenWebUI.
- Chats and settings are in `openwebui_db`; uploads and the vector store are lost with the aux-disk.
- Recovery: restart lxc230, then check PostgreSQL reachability, the aux-disk path and the backends.

## Related Documents

- [lxc230](../nodes/lxc230.md)
- [LLM inference](./llm-inference.md)
- [PostgreSQL platform](./postgresql-platform.md)
