# Runbook: OpenWebUI health check (lxc230)

- **Use when:** OpenWebUI at `https://ai-openwebui.<tailnet-id>.ts.net` is unreachable, errors, or
  loses chats; or after a host reboot that touched the aux-disk.
- **Duration:** 5-15 minutes.
- **Risk:** none for the checks, which only read state. Repairs are listed per failure mode.
- **Last exercised:** never.

OpenWebUI depends on four layers that fail separately: the aux-disk mount on the host, the Docker
Compose stack on lxc230, the PostgreSQL connection to lxc260 over the tailnet, and `tailscale serve`
in front of it. Work through them in order; the first failing check is the fault. All commands run
on the Proxmox host. Node details: [lxc230.md](../../docs/nodes/lxc230.md).

## Preconditions

- `pct status 230` and `pct status 260` both print `status: running`.

## Steps

1. Host mount.
   ```bash
   findmnt /mnt/aux-disk/openwebui
   ```
   Check: one mount entry. No output: the aux-disk is not mounted (`findmnt /mnt/aux-disk`,
   [KE-13](../../docs/platform/known-errors.md#ke-13)).

2. Bind mount inside lxc230.
   ```bash
   pct exec 230 -- findmnt /var/lib/openwebui
   pct exec 230 -- ls /var/lib/openwebui
   ```
   Check: a mount entry, and the directory lists `data/`, `containerd/`, `docker-data/`.

3. Compose stack.
   ```bash
   pct exec 230 -- docker compose -f /opt/openwebui/docker-compose.yml ps
   pct exec 230 -- docker compose -f /opt/openwebui/docker-compose.yml logs --tail 30
   ```
   Check: every service `running`; no `exited` or `restarting` entry; no database errors in the log.

4. Database reachability (lxc230 -> lxc260:5432 over the tailnet).
   ```bash
   pct exec 230 -- nc -zv <tailscale-ip-postgres> 5432
   ```
   Without `nc`, from inside the app container:
   ```bash
   pct exec 230 -- docker exec openwebui python3 -c "import socket; socket.create_connection(('<tailscale-ip-postgres>', 5432), 3); print('ok')"
   ```
   Check: `succeeded!` or `ok`.

5. Tailscale serve.
   ```bash
   pct exec 230 -- tailscale serve status
   ```
   Check: the output contains
   ```
   https://ai-openwebui.<tailnet-id>.ts.net (tailnet only)
   |-- / proxy http://127.0.0.1:3000
   ```

## Verification

The service is healthy when all five checks pass and a login at
`https://ai-openwebui.<tailnet-id>.ts.net` shows existing chats. A missing chat history with a working
login points at the database, not at the front end.

The inference backends (admin desktop and vm100, port 8080) are not part of this check; their absence
degrades answers without making the service unavailable. If chat works but no model answers, see
Admin -> Settings -> Connections and [llm-inference.md](../../docs/services/llm-inference.md).

## Failure modes

| Symptom | Cause | Action |
|---|---|---|
| Step 1 empty | aux-disk not mounted on the host | `findmnt /mnt/aux-disk`; KE-13 |
| Step 2 empty directory | Host mount came up after lxc230 started | `pct reboot 230` |
| Container `exited` | App crash or OOM | `docker compose logs --tail 50`; `dmesg` on the host for OOM |
| Container `restarting` | Database unreachable at startup or config error | Step 4 first, then the log |
| Step 4 fails | Tailscale down on lxc230 or lxc260, or ACL | `pct exec 230 -- tailscale status`; grant `tag:ai-stack -> tag:database:5432` (Rule 6 in [tailscale-acl.md](../../docs/platform/tailscale-acl.md)) |
| Database errors in the log | Wrong credentials in `.env` or `openwebui_db` missing | `pct exec 260 -- runuser -u postgres -- psql -l`; restore per [pg-restore.md](../database/pg-restore.md) |
| Step 5 shows no entry | Serve config lost | `pct exec 230 -- tailscale serve --bg --https=443 http://127.0.0.1:3000` |

## Rollback

Not applicable for the checks: every command in Steps reads state. Of the repairs, `pct reboot 230`
and `docker compose` restarts change no data; `tailscale serve --bg` is reversed with
`tailscale serve --https=443 off`.

## Background

OpenWebUI binds loopback only and is published through `tailscale serve`
([decision](../../docs/decisions/loopback-tailscale-serve.md)). Chats and settings live in
`openwebui_db` on lxc260 ([postgresql-platform.md](../../docs/services/postgresql-platform.md));
uploads and the vector store live on the aux-disk under `/var/lib/openwebui/data` and are lost with
it. See [openwebui.md](../../docs/services/openwebui.md).
