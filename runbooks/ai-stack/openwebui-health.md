# Runbook: OpenWebUI health check (CT230)

## Problem

OpenWebUI depends on three independent layers that can fail separately:
the aux-disk mount on the Proxmox host, the Docker Compose stack on CT230,
and the PostgreSQL database connection on CT260 over Tailnet.
A failure in any layer may render the service unavailable while the others
remain healthy, making a structured check sequence necessary.

## Preconditions

- Proxmox host shell or SSH session active
- CT230 is running: `pct status 230` -> `status: running`
- CT260 is running: `pct status 260` -> `status: running`

---

## Verification

### 1. Mounts (Proxmox host)

Verify the host-side path is mounted before checking inside the container.

```bash
# mp1 - local block storage (app state, uploads, vector store, Docker engine data)
findmnt /mnt/aux-disk/openwebui
```

Expected: a single mount entry. No output = mount missing.

---

### 2. Mounts (inside CT230)

Confirm the LXC bind-mount is visible from inside the container.

```bash
# mp1 - should list data/, containerd/, docker-data/
pct exec 230 -- ls /var/lib/openwebui
```

Expected: directory non-empty. Empty or "No such file" = bind-mount not propagated.

---

### 3. Container status

```bash
pct exec 230 -- docker compose -f /opt/openwebui/docker-compose.yml ps
```

Expected: all services in state `running`. Any `exited` or `restarting` entry
is a failure.

Check recent logs for errors:
```bash
pct exec 230 -- docker compose -f /opt/openwebui/docker-compose.yml logs --tail 30
```

---

### 4. PostgreSQL connectivity (CT230 -> CT260)

Verify CT230 can reach CT260 on port 5432 over Tailnet:

```bash
pct exec 230 -- nc -zv <tailscale-ip-ct260> 5432
```

Expected: `Connection to <tailscale-ip-ct260> 5432 port [tcp/postgresql] succeeded!`

If `nc` is not available, use `docker exec` into the running container:
```bash
pct exec 230 -- docker exec openwebui bash -c \
  "python3 -c \"import socket; s=socket.create_connection(('<tailscale-ip-ct260>', 5432), 3); print('ok'); s.close()\""
```

---

### 5. Tailscale Serve

Confirm the HTTPS frontend is active and serving the correct backend:

```bash
pct exec 230 -- tailscale serve status
```

Expected output includes:
```
https://ai-openwebui.<tailnet-id>.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:3000
```

If the serve entry is missing, reconfigure:
```bash
pct exec 230 -- tailscale serve --bg --https=443 http://127.0.0.1:3000
```

---

## Failure Modes

| Symptom | Likely Cause | Action |
|---|---|---|
| `findmnt` returns no output for `/mnt/aux-disk/openwebui` | aux disk not mounted on Proxmox host | Check `findmnt /mnt/aux-disk` on Proxmox host |
| `ls /var/lib/openwebui` empty inside CT230 | Host mount came up after the LXC started | `pct stop 230 && pct start 230` |
| Container in `exited` state | App crash or OOM | `docker compose logs --tail 50` for error; check `dmesg` for OOM |
| Container in `restarting` loop | DB unreachable at startup or config error | Check step 4 first; then inspect logs |
| `nc` to CT260:5432 fails | Tailscale down on CT230 or CT260, or ACL blocking | `pct exec 230 -- tailscale status`; verify tag:ai-stack -> tag:database ACL rule 5 |
| DB connection errors in app logs | Wrong credentials or DB `openwebui_db` missing | Connect to CT260 and verify: `pct exec 260 -- psql -U postgres -c '\l'` |
| `tailscale serve status` shows no entry | Serve config lost (container restart, Tailscale restart) | Re-run serve command from step 5 |

## Rollback

Nothing to roll back: every command in this runbook reads state, and none of them writes. The repair
actions live in the failure table above, and each names its own reversal there.

Written down rather than omitted, because "there is nothing to undo" and "nobody thought about it"
look identical in a document that simply has no such section.

---

## Notes

- All commands run from the Proxmox host via `pct exec`. No direct LXC shell required.
- The inference backends (`llama-server` on the admin desktop and vm100, port 8080) are not
  checked here - they are inference-only and their absence degrades functionality without making the service
  unavailable. Check OpenWebUI Admin -> Settings -> Connections if inference is broken but
  the service is otherwise healthy, and see [LLM Inference](../../docs/services/llm-inference.md).
- See: [OpenWebUI service docs](../../docs/services/openwebui.md)
- See: [LXC230 node docs](../../docs/nodes/lxc230.md)
- See: [PostgreSQL platform service](../../docs/services/postgresql-platform.md)
