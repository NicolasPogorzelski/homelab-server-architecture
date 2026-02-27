# Vaultwarden (LXC230)

Vaultwarden is deployed via Docker Compose inside an unprivileged Debian LXC container.

## Deployment

- Image: `vaultwarden/server:latest`
- Compose path (runtime): `/opt/vaultwarden/compose/docker-compose.yml`
- Persistent data: `/opt/vaultwarden` mounted to `/data` inside the container
- Healthcheck: HTTP probe against `http://localhost:80/`

## Security / Exposure

- Loopback-only binding: `127.0.0.1:8080 -> container:80`
- No public exposure / no router port forwarding
- Remote access follows the zero-trust overlay model (Tailscale)

## Identity / Permissions

- The container runs as a non-root service user (`user: "1000:1000"`)
- UID/GID alignment is explicitly handled to avoid permission issues across:
  - unprivileged LXC boundaries
  - mounted storage directories

## Secrets Handling

- Secrets (e.g. admin token) are provided via `.env`
- `.env`, database files and private keys are intentionally NOT committed to the repository
