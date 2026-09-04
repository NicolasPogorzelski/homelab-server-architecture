# Vaultwarden (LXC240)

**Withdrawn from service on 2026-09-01.** The guest is stopped, `onboot` is cleared, and the scrape
target and HTTPS probe are gone. Data on the share is retained until 2026-11-30. Reasoning and the
second phase: [decommissioning decision](../decisions/vaultwarden-decommission.md).

What follows describes the service as it ran.

Vaultwarden was deployed via Docker Compose inside an unprivileged Debian LXC container.

## Deployment

- Image: `vaultwarden/server:latest`
- Compose path (runtime): `/opt/vaultwarden/compose/docker-compose.yml`
- Persistent data: `/opt/vaultwarden` mounted to `/data` inside the container
- Healthcheck: HTTP probe against `http://localhost:80/`

Important:
- Vaultwarden uses SQLite for its database (`db.sqlite3`).
- The database resides at `/opt/vaultwarden`, which is a CIFS mount (`mp0` on LXC240 -> `/mnt/smb/vaultwarden`).
- This violated the KE-1 architectural rule (no database files on CIFS/SMB). The migration to PostgreSQL (lxc260) was the planned fix and never happened; the service was decommissioned instead, which is how KE-5 is closed. The PostgreSQL route stays as the reopening path in the decision record.
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

Not in effect while the service is withdrawn. The node's `tag:tier1` assignment still exists in the
Tailscale console until phase 2. What follows applied while the service ran.

- Exposed via Tailscale only (no LAN / no public ingress).
- Network policy is enforced via Tailscale ACL (node tags + ACL JSON).
- See: [docs/platform/tailscale-acl.md](../platform/tailscale-acl.md)

## Failure Impact

None while withdrawn. What follows applied while the service ran.

If the CIFS mount (`/opt/vaultwarden` -> `/mnt/smb/vaultwarden`) became unavailable:

- Vaultwarden could not access its SQLite database.
- Encryption keys could become inaccessible.
- Service startup could fail, or data integrity be compromised.

Backups of the database and key material were called critical and never existed beyond SnapRAID
parity, which protects against losing a disk and not against deletion or corruption.

## Related Documents

- [Decommissioning decision](../decisions/vaultwarden-decommission.md)
- [LXC240 Node](../nodes/lxc240.md)
- [Known Errors (KE-5)](../platform/known-errors.md)
- [PostgreSQL Platform Service](./postgresql-platform.md)
- [Tailscale ACL](../platform/tailscale-acl.md)
