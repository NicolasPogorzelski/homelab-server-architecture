# Monitoring

Monitoring is implemented using a Prometheus + Grafana stack running inside a dedicated unprivileged LXC container.

## Components

- Prometheus (`prom/prometheus`)
- Grafana (`grafana/grafana`)
- Node Exporter (`prom/node-exporter`)

## Security / Exposure

- Prometheus binds to loopback only (`127.0.0.1:9090`)
- Grafana binds to loopback only (`127.0.0.1:3000`)
- Node Exporter binds to loopback only (`127.0.0.1:9100`)
- No public exposure; remote access is handled through the zero-trust overlay model

## Prometheus Configuration (Current State)

- Scrape interval: 15 seconds
- Separate scrape jobs for:
  - Prometheus self-scrape
  - Node Exporter on the monitoring node
  - Node Exporter on the Proxmox host

Targets are intentionally anonymized in the repository.

## Alerting

- No Alertmanager deployed yet
- No alert rules committed yet
- Current usage is dashboard-based (Grafana) and manual inspection
