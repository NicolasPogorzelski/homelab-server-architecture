# Audiobookshelf (VM100)

Audiobookshelf is deployed via Docker Compose on VM100.

## Deployment

- Image: `ghcr.io/advplyr/audiobookshelf:2.35.1`
- Compose path (runtime): `/opt/docker/audiobookshelf/docker-compose.yml`
- Runs on port 13378/TCP

## Storage Integration

Media is read-only mounted from VM102 via systemd automount (SMB/autofs):

- `${ABS_AUDIOBOOKS_ROOT}` -> `/audiobooks:ro`
- `${ABS_PODCASTS_ROOT}` -> `/podcasts:ro`

Config and metadata use local persistent volumes on VM100.

## Access Model (Zero Trust)

- No public ingress / no router port forwarding.
- Audiobookshelf is published on `127.0.0.1:13378` only and reaches the tailnet through
  `tailscale serve --bg --tcp 13378 tcp://127.0.0.1:13378` on vm100. Since 2026-10-01 it is not
  reachable from the LAN; clients use `http://gpu-vm.<tailnet-id>.ts.net:13378` or the node's
  Tailscale IP (WireGuard-encrypted, no TLS hostname).
- Clients appear to Audiobookshelf as `127.0.0.1`, because `tailscale serve` forwards the TCP stream.
- Network policy enforced via Tailscale ACL (node tags + ACL JSON).
- See: [docs/platform/tailscale-acl.md](../platform/tailscale-acl.md)
- See: [Loopback + Tailscale Serve ADR](../decisions/loopback-tailscale-serve.md)

| Source | Port | Access |
|---|---|---|
| `tag:admin`, `tag:admin-mobile`, `tag:client`, `tag:reader` | 13378 | Allowed |
| One external user through machine sharing | 13378 | Allowed |
| `tag:monitoring` | 13378 | Allowed (blackbox probe) |
| `tag:untrusted`, `tag:tier0`, every other tag | 13378 | Denied |

## Failure Impact

If VM100 becomes unavailable:

- No audiobook or podcast streaming.
- No data loss - media is read-only from VM102 storage.
- Recovery: restart VM100, verify SMB automounts, confirm Docker containers are running.

## Related Documents

- [VM100 Node](../nodes/vm100.md)
- [Storage Design](../platform/storage-design.md)
- [Tailscale ACL](../platform/tailscale-acl.md)
