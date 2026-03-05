# Nextcloud (LXC210)

Nextcloud is deployed as a classic web application stack inside an unprivileged Debian LXC container.

## Components

- Webserver: Apache 2.4 (HTTP/80 + HTTPS/443)
- PHP: PHP 8.2 (Debian packages)
- Database: MariaDB/MySQL (local to the container; `dbhost=localhost`)
- Cache/Locking: APCu (local cache) + Redis (transaction/file locking)

## Runtime Configuration (Sanitized)

- Nextcloud version: 31.x
- Data directory: `/mnt/nextcloud` (mounted storage)
- DB type: `mysql`, database: `nextcloud`
- Redis: `127.0.0.1:6379` (local Redis instance)
- Trusted domains / overwrite URL: configured for LAN + Tailscale (values anonymized in repo)

## Data / Storage Integration

- Nextcloud application code: `/var/www/nextcloud`
- Persistent user data: CIFS-mounted storage at `/mnt/nextcloud`
- Ownership model: mapped to `www-data` inside the unprivileged container (UID/GID mapping via mount options)

Important:
- The database (MariaDB) runs locally inside the container and is not stored on CIFS.
- Redis is used for file locking to avoid concurrency issues.
- CIFS is used only for persistent user file storage.

This separation keeps:
- service runtime (container filesystem)
- persistent user data (storage mount)
cleanly decoupled.

## Failure Impact

If the CIFS mount becomes unavailable:
- Nextcloud may start but fail to access user data.
- Application errors will occur due to missing data directory.
- Monitoring should detect mount or storage degradation.

## Access Model (Zero Trust)

### Exposure
- No public reverse proxy.
- No router port forwarding.
- Service is not publicly reachable.

### Network Enforcement

- Remote access is provided via the Tailscale overlay network.
- LAN access is permitted within the private network to optimize large file uploads and reduce unnecessary traffic routing through the overlay.
- No public exposure or router port-forwarding is configured.
- Network policy is enforced through Tailscale ACL (node tags + ACL JSON).
- See: [docs/platform/tailscale-acl.md](../platform/tailscale-acl.md)

### Transport Security

- HTTPS is provided via Tailscale (MagicDNS + automatic certificates).
- TLS certificates are stored under `/var/lib/tailscale/certs/` and used by Apache vhosts.
- No publicly trusted certificates are exposed to the internet.

## Apache VirtualHosts (Conceptual)

- `*:80` internal HTTP vhost (e.g. for local access / redirect patterns)
- `*:443` HTTPS vhost using Tailscale-provided certificates

## Notes / Known Issues

- The container shows a failed `run-rpc_pipefs.mount` unit. This is non-blocking for Nextcloud operation and will be reviewed if NFS/RPC features are required.
