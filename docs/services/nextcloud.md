# Nextcloud (LXC210)

Nextcloud is deployed as a classic web application stack inside an unprivileged Debian LXC container.

## Components

- Webserver: Apache 2.4 (HTTP/80 + HTTPS/443)
- PHP: PHP 8.2 (Debian packages)
- Database: MariaDB/MySQL (local to the container; `dbhost=localhost`)

Note: MariaDB runs locally rather than on the centralized PostgreSQL platform (CT260).
Nextcloud's official documentation recommends MariaDB, and Nextcloud was deployed before
CT260 existed. Migration is not planned.
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

## External Storage (Paperless Integration)

The `files_external` app provides Nextcloud users with direct upload paths
into Paperless-ngx consumption directories.

Each mount points to a dedicated SMB share on VM102, scoped to a single
user's consumption subdirectory.

| Mount ID | Nextcloud User | SMB Share | Target Path |
|---|---|---|---|
| 4 | Nicolas | Paperless-ingest-Nico | `/mnt/mergerfs/Paperless/consumption/Nico` |
| 5 | Laura | Paperless-ingest-Laura | `/mnt/mergerfs/Paperless/consumption/Laura` |

- SMB user: `paperless-ingest` (global credentials, not per-session)
- Auth method: global credentials stored in Nextcloud config (not session-based)
- Files uploaded here are consumed and deleted by Paperless within ~30 seconds

### Cache Synchronization Cronjob

Paperless deletes consumed files from the SMB share. Nextcloud's file cache does not
detect these deletions automatically (External Storage mounts are not monitored in real time).

A scheduled `files:scan` on LXC210 keeps the cache consistent:

- Script: `/usr/local/sbin/scan-paperless-inbox.sh` (root, chmod 750)
- Schedule: `0 * * * *` (hourly, root crontab)
- Log: `/var/log/nextcloud-paperless-scan.log`
- Scope: scans `<user>/files/Paperless Inbox` per Nextcloud user; silently skips users without the folder

See: [Paperless-ngx Service Documentation](./paperless.md) — Nextcloud Integration section

## Notes / Known Issues

- The container shows a failed `run-rpc_pipefs.mount` unit. This is non-blocking for Nextcloud operation and will be reviewed if NFS/RPC features are required.
