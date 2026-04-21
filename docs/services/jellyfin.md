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

## Failure Impact

If VM100 becomes unavailable:

- No media streaming.
- No data loss — media is read-only from VM102 storage.
- Recovery: restart VM100, verify SMB automounts, confirm Docker containers are running.

## Related Documents

- [VM100 Node](../nodes/vm100.md)
- [Storage Design](../platform/storage-design.md)
- [Tailscale ACL](../platform/tailscale-acl.md)
