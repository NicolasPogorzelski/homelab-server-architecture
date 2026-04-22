# Monitoring

Monitoring is implemented using a Prometheus + Grafana stack running inside a dedicated unprivileged LXC container.

See: [Runbook index](../../runbooks/README.md)

## Components

- Prometheus (`prom/prometheus`)
- Grafana (`grafana/grafana`)
- Node Exporter (`prom/node-exporter`)
- Alertmanager (`prom/alertmanager`)
- postgres_exporter (`prom/postgres-exporter`, CT260)

## Security / Exposure

- Prometheus binds to loopback only (`127.0.0.1:9090`)
- Grafana binds to loopback only (`127.0.0.1:3000`)
- Node Exporter binds to loopback only (`127.0.0.1:9100`)
- No public exposure; remote access follows the zero-trust overlay model (Tailscale)
- Access is enforced via Tailscale ACL policy (tags + ACL JSON)
- See: [docs/platform/tailscale-acl.md](./tailscale-acl.md)

Remote access is provided via Tailscale (Serve or Tailnet-bound proxy). The services themselves do not listen on LAN interfaces.

## Prometheus Configuration (Current State)

- Scrape interval: 15 seconds
- 13 active scrape jobs — all UP, E2E verified 2026-04-22

| Job name | Target | Notes |
|---|---|---|
| `prometheus` | `127.0.0.1:9090` | Prometheus self-scrape |
| `node-lxc200-monitoring` | `127.0.0.1:9100` | node_exporter as Docker container (loopback) |
| `node-proxmox-host` | Proxmox host Tailscale IP`:9100` | textfile collector enabled (`smart.prom` active) |
| `node-vm102-storage` | VM102 Tailscale IP`:9100` | systemd binary, v1.11.1 |
| `node-vm100-gpu` | VM100 Tailscale IP`:9100` | systemd binary, v1.11.1 |
| `node-lxc210-nextcloud` | LXC210 Tailscale IP`:9100` | systemd binary, v1.11.1 |
| `node-lxc211-paperless` | LXC211 Tailscale IP`:9100` | systemd binary, v1.11.1 |
| `node-lxc220-calibreweb` | LXC220 Tailscale IP`:9100` | systemd binary, v1.11.1 |
| `node-lxc230-openwebui` | LXC230 Tailscale IP`:9100` | systemd binary, v1.11.1 |
| `node-lxc240-vaultwarden` | LXC240 Tailscale IP`:9100` | systemd binary, v1.11.1 |
| `node-lxc250-devops` | LXC250 Tailscale IP`:9100` | systemd binary, v1.11.1 |
| `node-ct260-postgres` | CT260 Tailscale IP`:9100` | systemd binary, v1.11.1 |
| `postgres` | CT260 Tailscale IP`:9187` | postgres_exporter v0.19.1, `pg_stat_*` via loopback |

Reference config: [`docker/monitoring/prometheus/prometheus.yml.example`](../../docker/monitoring/prometheus/prometheus.yml.example)

## Alerting

- Alertmanager deployed on LXC200 (`127.0.0.1:9093`), exposed via `tailscale serve --https=9093`
- Notification receiver: Discord webhook
- Alert rules active: `NodeDown`, `DiskSpaceCritical`, `HighMemoryUsage`, `PostgreSQLBackupStale`
- `PostgreSQLBackupStale` requires Node Exporter textfile collector on CT260 (see pg-backup runbook)

## Failure / Dependency Notes

Monitoring should start independently of application services and storage mounts where possible.
Dependencies must degrade gracefully without blocking the monitoring stack.
