# Audiobookshelf (VM100)

Audiobookshelf is deployed via Docker Compose on VM100.

## Deployment

- Image: `ghcr.io/advplyr/audiobookshelf:latest`
- Compose path (runtime): `/opt/homelab-server-architecture/docker/audiobookshelf/docker-compose.yml`
- Runs on port 13378/TCP

## Storage Integration

Media is read-only mounted from VM102 via systemd automount (SMB/autofs):

- `${ABS_AUDIOBOOKS_ROOT}` → `/audiobooks:ro`
- `${ABS_PODCASTS_ROOT}` → `/podcasts:ro`

Config and metadata use local persistent volumes on VM100.

## Access Model (Zero Trust)

- No public ingress / no router port forwarding.
- Audiobookshelf binds to `0.0.0.0:13378` for LAN streaming performance (documented trade-off).
- Remote access is via Tailscale IP directly (WireGuard-encrypted, no TLS hostname).
- LAN exposure is intentional and limited to port 13378 only.
- Network policy enforced via Tailscale ACL (node tags + ACL JSON).
- See: [docs/platform/tailscale-acl.md](../platform/tailscale-acl.md)
- See: [Loopback + Tailscale Serve ADR](../decisions/loopback-tailscale-serve.md) — section "Documented Exceptions"

| Source | Port | Access |
|---|---|---|
| `tag:client` | 13378 | Allowed |
| `tag:untrusted` | 13378 | Allowed |
| `tag:admin`, `tag:tier0` | all | Allowed |

## Failure Impact

If VM100 becomes unavailable:

- No audiobook or podcast streaming.
- No data loss — media is read-only from VM102 storage.
- Recovery: restart VM100, verify SMB automounts, confirm Docker containers are running.

## Related Documents

- [VM100 Node](../nodes/vm100.md)
- [Storage Design](../platform/storage-design.md)
- [Tailscale ACL](../platform/tailscale-acl.md)
