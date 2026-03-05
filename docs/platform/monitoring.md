# Monitoring

Monitoring is implemented using a Prometheus + Grafana stack running inside a dedicated unprivileged LXC container.

See: [Runbook index](../../runbooks/README.md)

## Components

- Prometheus (`prom/prometheus`)
- Grafana (`grafana/grafana`)
- Node Exporter (`prom/node-exporter`)

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
- Separate scrape jobs for:
  - Prometheus self-scrape
  - Node Exporter on the monitoring node (loopback)
  - Node Exporter on the Proxmox host (anonymized in repo)

## Alerting

- No Alertmanager deployed yet
- No alert rules committed yet
- Current usage is dashboard-based (Grafana) and manual inspection

## Failure / Dependency Notes

Monitoring should start independently of application services and storage mounts where possible.
Dependencies must degrade gracefully without blocking the monitoring stack.
