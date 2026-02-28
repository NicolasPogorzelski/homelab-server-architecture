# Calibre-Web (LXC212)

Calibre-Web is deployed via Docker Compose inside an unprivileged Debian LXC container.

## Deployment

- Image: `lscr.io/linuxserver/calibre-web:latest`
- Compose path (runtime): `/srv/calibreweb/docker-compose.yml`
- Persistent config: `/srv/calibreweb/config` mounted to `/config`

## Data / Storage Integration

- Library mount: `/books` (CIFS-mounted storage from the dedicated storage VM)
- Mount mode: read-only (`/books:/books:ro`) to enforce least-privilege for a consumer service

Important:
- The library is mounted read-only.
- Calibre-Web does not modify library files.
- No database or stateful workload is stored on CIFS.

## Security / Exposure

- Loopback-only binding: `127.0.0.1:8083 -> container:8083`
- No LAN exposure.
- No public ingress / no router port forwarding.
- Remote access is provided exclusively via Tailscale (identity-based overlay).

## Identity / Permissions

- Container process UID/GID configured via:
  - `PUID=1000`
  - `PGID=1000`
- Library is mounted read-only via CIFS.
- No stateful or write-heavy workload is stored on network mounts.
- Ownership consistency is preserved across unprivileged LXC + CIFS boundaries.

## Access Model (Zero Trust)

- Service acts as a **read-only consumer node** in the platform.
- No service-to-service provider role.
- Network segmentation is enforced via Tailscale ACL (node tags + policy rules).
- See: [docs/platform/tailscale-acl.md](../platform/tailscale-acl.md)

## Failure Impact

If the CIFS mount (`/books`) becomes unavailable:

- Calibre-Web may start but show an empty or inaccessible library.
- No data loss occurs due to read-only mount configuration.
- Monitoring should detect mount degradation.
