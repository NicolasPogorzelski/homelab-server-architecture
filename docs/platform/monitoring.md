# Monitoring

Prometheus, Grafana and Alertmanager run as a Docker Compose stack on lxc200
([node document](../nodes/lxc200.md)), an unprivileged LXC. Image versions are pinned in
`docker/monitoring/docker-compose.yml`.

See: [Runbook index](../../runbooks/README.md)

## Components

- Prometheus, Grafana, Alertmanager, Blackbox Exporter and a containerised Node Exporter on lxc200.
- `node_exporter` as a native systemd service on every node, managed by the `node_exporter` role.
- `postgres_exporter` as a systemd service on lxc260, managed by the `postgres_exporter` role.
- Textfile collectors written by timers on the nodes (SnapRAID, backups, SMART, apt, listeners,
  fleet snapshot and drift).

## Security / Exposure

- Prometheus (`127.0.0.1:9090`), Grafana (`127.0.0.1:3000`), Alertmanager (`127.0.0.1:9093`) and
  the containerised Node Exporter (`127.0.0.1:9100`) bind loopback only.
- Remote access goes through `tailscale serve` and the tailnet ACL
  ([tailscale-acl.md](tailscale-acl.md)); nothing listens on the LAN.
- Every native exporter binds its node's Tailscale address, gated on that address existing at boot.

## Prometheus Configuration

- Scrape interval: 15 seconds.
- Source: `ansible/roles/prometheus_config/templates/prometheus.yml.j2`, rendered from the
  inventory by the `prometheus_config` role. Node targets are generated per inventory host, so a
  node in the inventory is scraped without a template edit.

| Job name | Target | Notes |
|---|---|---|
| `prometheus` | `127.0.0.1:9090` | self-scrape |
| `node-lxc200-monitoring` | `127.0.0.1:9100` | containerised exporter; resources only, no unit state |
| `node-lxc200-monitoring-systemd` | lxc200 Tailscale IP`:9101` | native exporter with the systemd collector ([decision](../decisions/lxc200-systemd-visibility.md)) |
| `node-proxmox-host` | host Tailscale IP`:9100` | systemd and textfile collectors (SMART, thin pool, guest and host-config backup) |
| `node-<host>-<label>` | guest Tailscale IP`:9100` | one job per guest from the inventory: vm100, vm102, lxc210, lxc211, lxc220, lxc230, lxc250, lxc260 |
| `postgres` | lxc260 Tailscale IP`:9187` | `postgres_exporter`, `pg_stat_*` over loopback |
| `blackbox-http` | via `127.0.0.1:9115` | `http_2xx`: Jellyfin, Audiobookshelf, llama-server `/health` on vm100 |
| `blackbox-https` | via `127.0.0.1:9115` | `http_service_up` behind `tailscale serve`: Paperless, OpenWebUI, Nextcloud, Calibre-Web |

## Alerting

- Alertmanager on lxc200, exposed with `tailscale serve --https=9093`; receiver: a Discord webhook.
- Rules: `docker/monitoring/prometheus/rules/alert.rules.yml` (owner of every threshold). The
  validator holds the table below against the rules file, and `FleetRulesMismatch` holds the
  rules file against what Prometheus has loaded.

| Group | Rules |
|---|---|
| `node` | `NodeDown`, `DiskSpaceCritical`, `HighMemoryUsage`, `PostgreSQLBackupStale`, `PostgreSQLRestoreTestStale`, `MariaDBRestoreTestStale`, `MariaDBBackupStale`, `DatabaseBackupMetricsMissing` |
| `postgres` | `PostgreSQLDown`, `PostgreSQLConnectionsHigh` |
| `snapraid` | `SnapRAIDSyncStale`, `SnapRAIDScrubStale`, `SnapRAIDScrubCoverageAging`, `SnapRAIDArrayUnscrubbed`, `SnapRAIDStatusStale`, `SnapRAIDStatusUnreadable` |
| `storage` | `ArchivePoolLowSpace`, `StoragePermissionDrift`, `StoragePermissionCheckStale` |
| `lvm` | `LvmThinPoolWarning`, `LvmThinPoolCritical`, `LvmThinPoolMetadataCritical`, `LvmThinMetricsStale` |
| `systemd` | `SystemdUnitFailed` |
| `backup` | `GuestBackupStale`, `GuestBackupPartial`, `GuestBackupMetricsMissing`, `HostConfigBackupStale`, `AppBackupStale`, `AppBackupMetricsMissing`, `BackupMirrorStale`, `BackupMirrorFailed`, `BackupMirrorMetricsMissing` |
| `offsite` | `OffsiteBackupFailed`, `OffsiteBackupStale`, `OffsiteBackupUnverified` |
| `snapshot` | `FleetSnapshotStale`, `FleetSnapshotIncomplete` |
| `drift` | `FleetDriftUnexpected`, `FleetDriftStale`, `FleetDriftIncomplete`, `FleetRulesMismatch`, `FleetRulesUnverified`, `PrometheusRuleEvaluationFailing` |
| `kernel` | `FilesystemMountTimeout`, `SystemdUnitStuckActivating` |
| `heartbeat` | `Watchdog` |
| `blackbox` | `ServiceDown` |
| `upstream` | `UpstreamFixReleased`, `UpstreamWatchStale`, `UpstreamWatchFailed` |
| `smart` | `SmartAttributeDegrading`, `SmartUdmaCrcErrorsGrowing`, `SmartReallocatedSectors`, `SmartWearLevelingLow`, `SmartMetricsStale` |
| `apt` | `AptSecurityUpdatesPending`, `AptMetricsStale` |
| `listeners` | `ListenerOutsideBindingRule`, `ListenerMetricsStale`, `ListenerMetricsMissing` |
| `jellyfin` | `JellyfinCudaLost` |
| `ingest` | `PaperlessIngestStorageDown`, `PaperlessInboxScanStale`, `PaperlessIngestMetricsMissing` |

### Notes on specific rules

- **Database backups.** `PostgreSQLBackupStale` and `MariaDBBackupStale` read textfile timestamps
  on lxc260 and lxc210 ([pg-backup](../../runbooks/database/pg-backup.md),
  [mariadb-backup](../../runbooks/database/mariadb-backup.md)). They cannot see an outage in which
  the host is off: Prometheus runs on the same host, and the timer's `Persistent=true` catch-up
  refreshes the timestamp before the first scrape. The rule means "no more than 25 hours of uptime
  without a backup". Details in [postgresql-platform.md](../services/postgresql-platform.md#backup-strategy).
- **Missing metrics.** `DatabaseBackupMetricsMissing` fires when any of the four database
  timestamps (both backups, both restore tests) is absent, the case in which a staleness rule
  evaluates to nothing and never turns red. Each absence carries a `metric` label.
- **SnapRAID.** `SnapRAIDScrubStale` reads when a scrub last succeeded and fires after 10 days;
  the scrub runs weekly (`snapraid_maintenance` defaults). It cannot show how much of the array a
  scrub reached, so `SnapRAIDScrubCoverageAging` (oldest block over 200 days) and
  `SnapRAIDArrayUnscrubbed` read `snapraid status` from a separate status timer, and
  `SnapRAIDStatusStale` / `SnapRAIDStatusUnreadable` cover that reading stopping.
- **Fleet snapshot and drift.** `fleet-snapshot.yml` records state no role owns (sockets, local
  units, crontabs, mounts, images); `fleet-drift.sh` runs the drift sweep with `--check`. Both
  write into the textfile collector on lxc250 ([ansible.md](ansible.md#roles)).
- **Blackbox.** `ServiceDown` fires on the `blackbox-http` and `blackbox-https` targets
  ([KE-8](known-errors.md#ke-8)).
- **Pending state across the off-window.** Prometheus restores a pending alert's `for:` after a
  restart only if the outage was shorter than `--rules.alert.for-outage-tolerance`, set to 48 h
  in the compose file. An alert whose `for:` is longer than one day of uptime depends on it
  ([KE-31](known-errors.md#ke-31)).

### Watchdog and the missing heartbeat

`Watchdog` fires permanently; its absence is the signal. It is meant to be routed to an external
heartbeat receiver whose grace period exceeds the nightly off-window, so that the alerting chain
being down - including the host being off - is noticed off site. The route is defined in
`docker/monitoring/alertmanager/alertmanager.yml.example`.

Verified 2026-09-24: the live `alertmanager.yml` on lxc200 still has only the `discord` route, so
the Watchdog arrives in Discord and nothing outside the site notices when it stops. The route and
the receiver go live together; the item is in the [remediation plan](remediation-plan.md).

## Failure / Dependency Notes

The monitoring stack must start without application services or storage mounts, and a failing
dependency must not block it. Monitoring is down whenever the host is off.
