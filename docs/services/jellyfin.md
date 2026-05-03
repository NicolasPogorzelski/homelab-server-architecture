# Jellyfin (VM100)

Jellyfin is deployed via Docker Compose on VM100 with NVIDIA GPU hardware transcoding.

## Deployment

- Image: `jellyfin/jellyfin:latest`
- Compose path (runtime): `/opt/homelab-server-architecture/docker/jellyfin/docker-compose.yml`
- GPU acceleration: enabled (`gpus: all`, NVIDIA runtime)
- Runs as non-root user (`user: 1000:1000`)

## Storage Integration

Media is read-only mounted from VM102 via systemd automount (SMB/autofs):

- `${JF_MEDIA_FILME}` → `/media/Filme:ro`
- `${JF_MEDIA_SERIEN}` → `/media/Serien:ro`

Config, cache, and metadata use local persistent volumes on VM100.

## Access Model (Zero Trust)

- No public ingress / no router port forwarding.
- Jellyfin binds to `0.0.0.0:8096` for LAN streaming performance (documented trade-off).
- Remote access is via Tailscale IP directly (WireGuard-encrypted, no TLS hostname).
- LAN exposure is intentional and limited to port 8096 only.
- Network policy enforced via Tailscale ACL (node tags + ACL JSON).
- See: [docs/platform/tailscale-acl.md](../platform/tailscale-acl.md)
- See: [Loopback + Tailscale Serve ADR](../decisions/loopback-tailscale-serve.md) — section "Documented Exceptions"

| Source | Port | Access |
|---|---|---|
| `tag:client` | 8096 | Allowed |
| `tag:untrusted` | 8096 | Allowed |
| `tag:admin`, `tag:tier0` | all | Allowed |

## CUDA Watchdog

Jellyfin intermittently loses CUDA access at runtime (see [KE-8](../platform/known-errors.md#ke-8-jellyfin-loses-cuda-access-intermittently--container-restart-required)).
A watchdog script checks GPU availability every 30 minutes and restarts the container if access is lost.

### Deploy on VM100

```bash
install -m 0755 -o root -g root /dev/null /usr/local/sbin/jellyfin-cuda-watchdog.sh
# copy content from snippets/scripts/jellyfin-cuda-watchdog.sh
```

### Cron entry (root crontab on VM100)

```
*/30 * * * * /usr/local/sbin/jellyfin-cuda-watchdog.sh
```

Add via `crontab -e` as root. Logs land in syslog — verify with:

```bash
grep jellyfin-cuda-watchdog /var/log/syslog
```

### Script reference

[snippets/scripts/jellyfin-cuda-watchdog.sh](../../snippets/scripts/jellyfin-cuda-watchdog.sh)

---

## Failure Impact

If VM100 becomes unavailable:

- No media streaming.
- No data loss — media is read-only from VM102 storage.
- Recovery: restart VM100, verify SMB automounts, confirm Docker containers are running.

## Related Documents

- [VM100 Node](../nodes/vm100.md)
- [Storage Design](../platform/storage-design.md)
- [Tailscale ACL](../platform/tailscale-acl.md)
