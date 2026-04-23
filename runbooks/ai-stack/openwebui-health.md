# Runbook: OpenWebUI health check (CT230)

## Problem

OpenWebUI depends on three independent layers that can fail separately:
SMB and local mounts on the Proxmox host, the Docker Compose stack on CT230,
and the PostgreSQL database connection on CT260 over Tailnet.
A failure in any layer may render the service unavailable while the others
remain healthy, making a structured check sequence necessary.

## Preconditions

- Proxmox host shell or SSH session active
- CT230 is running: `pct status 230` → `status: running`
- CT260 is running: `pct status 260` → `status: running`
- VM102 is running and Samba is active (required for SMB mounts)

---

## Verification

### 1. Mounts (Proxmox host)

Verify both host-side paths are mounted before checking inside the container.

```bash
# mp0 — SMB (uploads, vector store, backups)
findmnt -t cifs /mnt/smb/openwebui

# mp1 — local block storage (app state, logs)
findmnt /mnt/aux1TB/openwebui
```

Expected: both commands print a single mount entry. No output = mount missing.

If `mp0` is missing, trigger the autofs mount:
```bash
ls /mnt/smb/openwebui
findmnt -t cifs /mnt/smb/openwebui
```

See: [SMB autofs trigger runbook](../storage/smb-autofs-trigger.md)

---

### 2. Mounts (inside CT230)

Confirm the LXC bind-mounts are visible from inside the container.

```bash
# mp0 — should list uploads/, vector/, backups/
pct exec 230 -- ls /data/openwebui

# mp1 — should list OpenWebUI app state directories
pct exec 230 -- ls /var/lib/openwebui
```

Expected: both directories non-empty. Empty or "No such file" = bind-mount not propagated.

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

### 4. PostgreSQL connectivity (CT230 → CT260)

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
| `findmnt` returns no output for `/mnt/smb/openwebui` | autofs not triggered or VM102 Samba down | `ls /mnt/smb/openwebui` to trigger; verify VM102 |
| `findmnt` returns no output for `/mnt/aux1TB/openwebui` | Aux1TB disk not mounted on Proxmox host | Check `findmnt /mnt/aux1TB` on Proxmox host |
| `ls /data/openwebui` empty inside CT230 | Host SMB mount active but LXC bind-mount not propagated | `pct stop 230 && pct start 230` |
| Container in `exited` state | App crash or OOM | `docker compose logs --tail 50` for error; check `dmesg` for OOM |
| Container in `restarting` loop | DB unreachable at startup or config error | Check step 4 first; then inspect logs |
| `nc` to CT260:5432 fails | Tailscale down on CT230 or CT260, or ACL blocking | `pct exec 230 -- tailscale status`; verify tag:ai-stack → tag:database ACL rule 5 |
| DB connection errors in app logs | Wrong credentials or DB `openwebui_db` missing | Connect to CT260 and verify: `pct exec 260 -- psql -U postgres -c '\l'` |
| `tailscale serve status` shows no entry | Serve config lost (container restart, Tailscale restart) | Re-run serve command from step 5 |

---

## Notes

- All commands run from the Proxmox host via `pct exec`. No direct LXC shell required.
- Ollama backends (Gaming PC port 11434, VM100 port 11434) are not checked here —
  they are inference-only and their absence degrades functionality without making the service
  unavailable. Check OpenWebUI Admin → Settings → Connections if inference is broken but
  the service is otherwise healthy.
- See: [OpenWebUI service docs](../../docs/services/openwebui.md)
- See: [LXC230 node docs](../../docs/nodes/lxc230.md)
- See: [PostgreSQL platform service](../../docs/services/postgresql-platform.md)
