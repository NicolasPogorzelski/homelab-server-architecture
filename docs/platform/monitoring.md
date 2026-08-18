# Monitoring

Monitoring is implemented using a Prometheus + Grafana stack running inside a dedicated unprivileged LXC container.

See: [Runbook index](../../runbooks/README.md)

## Components

- Prometheus (`prom/prometheus`)
- Grafana (`grafana/grafana`)
- Node Exporter (`prom/node-exporter`)
- Alertmanager (`prom/alertmanager`)
- postgres_exporter v0.19.1 on lxc260 - a systemd binary, not a container, and not a `prom/*`
  image: upstream is `prometheuscommunity/postgres-exporter`. The entry named the wrong artefact
  until 2026-08-17 while the target table below described it correctly.
- Blackbox Exporter (`prom/blackbox-exporter`) - service-level HTTP(S) probes (KE-8 remediation)

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
- 14 active scrape jobs (19 targets) - all UP, re-verified 2026-08-13 against the Prometheus API
- **LXC250 is not among the targets.** It sits in no inventory group, so the template renders no
  target for it - yet it *does* run a `node_exporter` (hand-installed, binding `*:9100`, scraped
  by nobody). See [LXC250 § Open Items](../nodes/lxc250.md#open-items-2026-07-28)

| Job name | Target | Notes |
|---|---|---|
| `prometheus` | `127.0.0.1:9090` | Prometheus self-scrape |
| `node-lxc200-monitoring` | `127.0.0.1:9100` | node_exporter as Docker container (loopback) |
| `node-proxmox-host` | Proxmox host Tailscale IP`:9100` | systemd + textfile collector (`smart.prom`, `lvm-thin.prom`) |
| `node-vm102-storage` | VM102 Tailscale IP`:9100` | systemd binary, v1.11.1; textfile collector enabled (`snapraid_sync.prom`, `snapraid_scrub.prom`) |
| `node-vm100-gpu` | VM100 Tailscale IP`:9100` | systemd binary, v1.11.1 |
| `node-lxc210-nextcloud` | LXC210 Tailscale IP`:9100` | systemd binary, v1.11.1 |
| `node-lxc211-paperless` | LXC211 Tailscale IP`:9100` | systemd binary, v1.11.1 |
| `node-lxc220-calibreweb` | LXC220 Tailscale IP`:9100` | systemd binary, v1.11.1 |
| `node-lxc230-openwebui` | LXC230 Tailscale IP`:9100` | systemd binary, v1.11.1 |
| `node-lxc240-vaultwarden` | LXC240 Tailscale IP`:9100` | systemd binary, v1.11.1 |
| `node-lxc260-postgres` | LXC260 Tailscale IP`:9100` | systemd binary, v1.11.1 |
| `postgres` | LXC260 Tailscale IP`:9187` | postgres_exporter v0.19.1, `pg_stat_*` via loopback |
| `blackbox-http` | via `127.0.0.1:9115` | HTTP probes (`http_2xx`): jellyfin, audiobookshelf |
| `blackbox-https` | via `127.0.0.1:9115` | HTTPS probes (`http_service_up`) behind `tailscale serve`: paperless, openwebui, nextcloud, calibreweb, vaultwarden |

Reference config: [`docker/monitoring/prometheus/prometheus.yml.example`](../../docker/monitoring/prometheus/prometheus.yml.example)

## Alerting

- Alertmanager deployed on LXC200 (`127.0.0.1:9093`), exposed via `tailscale serve --https=9093`
- Notification receiver: Discord webhook
- **The table below is the count.** This line used to carry a number as well, and it was wrong
  three times in a row: "15" while the table listed 16, then "17" while the file and the live
  Prometheus both held 19 in 8 groups - the `storage` group had grown by two and the prose was not
  recounted. A number in prose beside a table that already contains it has no owner and only one
  possible future. It is gone rather than corrected. The `smart` group is present in the rules file
  and deliberately empty, which is why the Prometheus API returns one group fewer than the file
  defines.

| Group | Rules |
|---|---|
| `node` | `NodeDown`, `DiskSpaceCritical`, `HighMemoryUsage`, `PostgreSQLBackupStale`, `PostgreSQLRestoreTestStale`, `MariaDBBackupStale` |
| `postgres` | `PostgreSQLDown`, `PostgreSQLConnectionsHigh` |
| `snapraid` | `SnapRAIDSyncStale`, `SnapRAIDScrubStale` |
| `storage` | `ArchivePoolLowSpace`, `StoragePermissionDrift`, `StoragePermissionCheckStale` |
| `lvm` | `LvmThinPoolWarning`, `LvmThinPoolCritical`, `LvmThinPoolMetadataCritical`, `LvmThinMetricsStale` |
| `systemd` | `SystemdUnitFailed` |
| `blackbox` | `ServiceDown` |
| `smart` | *(empty - the host exports only `smart_health_passed` / `smart_temperature_celsius`, and the first reads `1` for a disk with 7680 unreadable sectors. See [KE-13](./known-errors.md#ke-13) and the SMART item in [`operations.md`](./operations.md).)* |
- `ServiceDown` fires on the `blackbox-http` / `blackbox-https` probe targets (service-level HTTP(S) reachability; KE-8 remediation)
- `PostgreSQLBackupStale` requires Node Exporter textfile collector on lxc260 (see pg-backup runbook).
  **It cannot see an outage in which the host is off**, because Prometheus runs on that same host:
  no scrape happens, and by the time Prometheus returns, the timer's `Persistent=true` catch-up has
  already refreshed the timestamp. Measured 2026-08-14 - a 62-hour scrape gap (2026-08-10 21:50 to
  2026-08-13 11:50) with no dump written and the alert empty across the whole range. The rule means
  "not more than 25 hours of uptime without a backup", not "a backup every day". Detail and
  reasoning in [`postgresql-platform.md`](../services/postgresql-platform.md#backup-strategy).
- `MariaDBBackupStale` requires the Node Exporter textfile collector on lxc210 (see the
  [MariaDB backup runbook](../../runbooks/database/mariadb-backup.md)). It carries the same
  host-is-off blind spot as the PostgreSQL rule above, for the same structural reason. It covers
  Nextcloud's own database, which the nightly `pg_dumpall` never touched - a gap that existed
  unnoticed until the 2026-08-15 data classification looked for it.
- `SnapRAIDSyncStale` / `SnapRAIDScrubStale` require Node Exporter textfile collector on VM102 (`--collector.textfile.directory=/var/lib/node_exporter/textfile_collector`); written by `snapraid-maintenance.sh`

## Failure / Dependency Notes

Monitoring should start independently of application services and storage mounts where possible.
Dependencies must degrade gracefully without blocking the monitoring stack.
