# Calibre-Web (LXC212)

Calibre-Web is deployed via Docker Compose inside an unprivileged Debian LXC container.

## Deployment

- Image: `lscr.io/linuxserver/calibre-web:latest`
- Compose path (runtime): `/srv/calibreweb/docker-compose.yml`
- Persistent config: `/srv/calibreweb/config` mounted to `/config`

## Data / Storage Integration

- Library mount: `/books` (CIFS-mounted storage from the dedicated storage VM)
- Mount mode: read-only (`/books:/books:ro`) to enforce least-privilege for a consumer service

## Security / Exposure

- Loopback-only binding: `127.0.0.1:8083 -> container:8083`
- No public exposure / no router port forwarding
- Remote access follows the zero-trust overlay model (Tailscale)

## Identity / Permissions

- Container process UID/GID configured via:
  - `PUID=1000`
  - `PGID=1000`
- This supports consistent ownership handling across storage boundaries (unprivileged LXC + CIFS mounts).
