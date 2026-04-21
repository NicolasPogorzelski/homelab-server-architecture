# Vaultwarden (LXC240)

Vaultwarden is deployed via Docker Compose inside an unprivileged Debian LXC container.

## Deployment

- Image: `vaultwarden/server:latest`
- Compose path (runtime): `/opt/vaultwarden/compose/docker-compose.yml`
- Persistent data: `/opt/vaultwarden` mounted to `/data` inside the container
- Healthcheck: HTTP probe against `http://localhost:80/`

Important:
- Vaultwarden uses SQLite for its database (`db.sqlite3`).
- The database resides at `/opt/vaultwarden`, which is a CIFS mount (`mp0` on LXC240 → `/mnt/smb/vaultwarden`).
- This violates the KE-1 architectural rule (no database files on CIFS/SMB). Migration to PostgreSQL (CT260) is planned.
- See: [KE-5](../platform/known-errors.md#ke-5-vaultwarden-sqlite-on-cifs--acknowledged-technical-debt)

## Security / Exposure

- Loopback-only binding: `127.0.0.1:8080 -> container:80`
- No LAN exposure
- No public exposure / no router port forwarding
- Remote access is provided exclusively via Tailscale (identity-based overlay).
- Network policy is enforced via Tailscale ACL (node tags + ACL JSON).
- See: [docs/platform/tailscale-acl.md](../platform/tailscale-acl.md)

## Identity / Permissions

- The container runs as a non-root service user (`user: "1000:1000"`)
- UID/GID alignment is explicitly handled to avoid permission issues across:
  - unprivileged LXC boundaries
  - mounted storage directories

## Secrets Handling

- Secrets (e.g. admin token) are provided via `.env`
- `.env`, database files and private keys are intentionally NOT committed to the repository

## Access Model (Zero Trust)
- Exposed via Tailscale only (no LAN / no public ingress).
- Network policy is enforced via Tailscale ACL (node tags + ACL JSON).
- See: [docs/platform/tailscale-acl.md](../platform/tailscale-acl.md)

## Failure Impact

If the CIFS mount (`/opt/vaultwarden` → `/mnt/smb/vaultwarden`) becomes unavailable:

- Vaultwarden cannot access its SQLite database.
- Encryption keys may become inaccessible.
- Service startup may fail or data integrity may be compromised.

Backups of the database and key material are critical.

## Related Documents

- [LXC240 Node](../nodes/lxc240.md)
- [Known Errors (KE-5)](../platform/known-errors.md)
- [PostgreSQL Platform Service](./postgresql-platform.md)
- [Tailscale ACL](../platform/tailscale-acl.md)
