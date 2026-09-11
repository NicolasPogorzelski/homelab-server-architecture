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
- 14 active scrape jobs (18 targets) - all UP, re-verified 2026-09-04 against the Prometheus API
- **LXC250 joined the targets on 2026-08-20.** It had sat in no inventory group, so the template
  rendered no target for it - while the node did run a `node_exporter`, hand-installed, binding
  `*:9100`, scraped by nobody. `systemctl is-active` reported `active` throughout, which is why
  the gap survived: the check that would have found it was answered by the wrong question. The
  role's unit replaced it, and the target now reports `up`

| Job name | Target | Notes |
|---|---|---|
| `prometheus` | `127.0.0.1:9090` | Prometheus self-scrape |
| `node-lxc200-monitoring` | `127.0.0.1:9100` | node_exporter as Docker container (loopback) |
| `node-proxmox-host` | Proxmox host Tailscale IP`:9100` | systemd + textfile collector (`smartmon.prom`, `lvm-thin.prom`, `guest-backup.prom`) |
| `node-vm102-storage` | VM102 Tailscale IP`:9100` | systemd binary, v1.11.1; textfile collector enabled (`snapraid_sync.prom`, `snapraid_scrub.prom`) |
| `node-vm100-gpu` | VM100 Tailscale IP`:9100` | systemd binary, v1.11.1 |
| `node-lxc210-nextcloud` | LXC210 Tailscale IP`:9100` | systemd binary, v1.11.1 |
| `node-lxc211-paperless` | LXC211 Tailscale IP`:9100` | systemd binary, v1.11.1 |
| `node-lxc220-calibreweb` | LXC220 Tailscale IP`:9100` | systemd binary, v1.11.1 |
| `node-lxc230-openwebui` | LXC230 Tailscale IP`:9100` | systemd binary, v1.11.1 |
| `node-lxc250-devops` | LXC250 Tailscale IP`:9100` | systemd binary, v1.11.1; added 2026-08-20, replacing a hand-written unit that bound `*:9100` |
| `node-lxc260-postgres` | LXC260 Tailscale IP`:9100` | systemd binary, v1.11.1 |
| `postgres` | LXC260 Tailscale IP`:9187` | postgres_exporter v0.19.1, `pg_stat_*` via loopback |
| `blackbox-http` | via `127.0.0.1:9115` | HTTP probes (`http_2xx`): jellyfin, audiobookshelf |
| `blackbox-https` | via `127.0.0.1:9115` | HTTPS probes (`http_service_up`) behind `tailscale serve`: paperless, openwebui, nextcloud, calibreweb |

Reference config: [`docker/monitoring/prometheus/prometheus.yml.example`](../../docker/monitoring/prometheus/prometheus.yml.example)

## Alerting

- Alertmanager deployed on LXC200 (`127.0.0.1:9093`), exposed via `tailscale serve --https=9093`
- Notification receiver: Discord webhook
- **The table below is the count.** This line used to carry a number as well, and it was wrong
  three times in a row: "15" while the table listed 16, then "17" while the file and the live
  Prometheus both held 19 in 8 groups - the `storage` group had grown by two and the prose was not
  recounted. A number in prose beside a table that already contains it has no owner and only one
  possible future. It is gone rather than corrected. The table then drifted the same way: on
  2026-09-08 it sat two groups and five rules behind the file, never having grown with `backup`
  and `kernel`. Check 38 holds the two lists against each other on every run. The `smart` group
  was present and deliberately empty until 2026-09-09, so the Prometheus API returned one group
  fewer than the file defined; it now carries rules and the two counts agree.

| Group | Rules |
|---|---|
| `node` | `NodeDown`, `DiskSpaceCritical`, `HighMemoryUsage`, `PostgreSQLBackupStale`, `PostgreSQLRestoreTestStale`, `MariaDBBackupStale` |
| `postgres` | `PostgreSQLDown`, `PostgreSQLConnectionsHigh` |
| `snapraid` | `SnapRAIDSyncStale`, `SnapRAIDScrubStale`, `SnapRAIDScrubCoverageAging`, `SnapRAIDArrayUnscrubbed`, `SnapRAIDStatusStale`, `SnapRAIDStatusUnreadable` |
| `storage` | `ArchivePoolLowSpace`, `StoragePermissionDrift`, `StoragePermissionCheckStale` |
| `lvm` | `LvmThinPoolWarning`, `LvmThinPoolCritical`, `LvmThinPoolMetadataCritical`, `LvmThinMetricsStale` |
| `systemd` | `SystemdUnitFailed` |
| `backup` | `GuestBackupStale`, `GuestBackupPartial`, `GuestBackupMetricsMissing` |
| `offsite` | `OffsiteBackupFailed`, `OffsiteBackupStale`, `OffsiteBackupUnverified`, `OffsiteBackupMetricsMissing` |
| `snapshot` | `FleetSnapshotStale`, `FleetSnapshotIncomplete` |
| `drift` | `FleetDriftUnexpected`, `FleetDriftStale`, `FleetDriftIncomplete`, `FleetRulesMismatch`, `FleetRulesUnverified` |
| `kernel` | `FilesystemMountTimeout`, `SystemdUnitStuckActivating` |
| `heartbeat` | `Watchdog` |
| `blackbox` | `ServiceDown` |
| `smart` | `SmartAttributeDegrading`, `SmartReallocatedSectors`, `SmartWearLevelingLow`, `SmartMetricsStale` |
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
- `FleetSnapshotStale` / `FleetSnapshotIncomplete` are written by `fleet-snapshot.yml` into the
  textfile collector on lxc250 (see the [`fleet_snapshot` role](ansible.md)). The snapshot records
  what no role owns - listening sockets, locally-defined unit files, root crontabs, mounts and
  running images - because an `ansible-playbook --check` sweep can only report on state a role
  already manages. Measured 2026-09-08: `ssh-hardening.yml --check` calls vm100 clean while its
  sshd listens on the wildcard address.
- The `drift` group is written by `fleet-drift.sh` on lxc250 (see the [`fleet_drift` role](ansible.md)).
  It answers the question the repository checks cannot: `validate-repo.sh` compares documents
  against files, and this compares files against nodes. Measured 2026-09-08, all 39 repository
  checks passed while thirteen playbooks reported drift on the live fleet. `FleetRulesMismatch`
  reaches one layer further still, comparing the alert names Prometheus has loaded against the
  rules file here - a deployed-but-not-reloaded file is the [KE-16](known-errors.md#ke-16) shape.
- `SnapRAIDSyncStale` / `SnapRAIDScrubStale` require Node Exporter textfile collector on VM102 (`--collector.textfile.directory=/var/lib/node_exporter/textfile_collector`); written by `snapraid-maintenance.sh`
- **The four coverage rules beside them exist because `SnapRAIDScrubStale` measures the wrong
  thing.** It reads when a scrub last succeeded. Measured 2026-08-17, it was green while the oldest
  block in the array had gone 123 days unverified and 74 % of the array had never been scrubbed at
  all - the job had run and reached almost nothing. `snapraid status` prints both figures, so
  `SnapRAIDScrubCoverageAging` and `SnapRAIDArrayUnscrubbed` read them from a `status` timer that
  runs independently of the sync, and `SnapRAIDStatusStale` / `SnapRAIDStatusUnreadable` cover the
  case where the reading itself stops. The thresholds sit above the current measurement on purpose:
  a monthly scrub at snapraid's default 8 % needs about a year for a full pass, so a rule set where
  the numbers ought to be would be red from its first evaluation and learned as noise. The scrub
  cadence is the open question, and it is in the remediation plan rather than encoded in a
  threshold here
- `Watchdog` fires permanently and is the only rule here whose *absence* is the signal. It is routed
  to an external heartbeat receiver rather than to Discord, and if that receiver stops seeing it the
  alerting chain is down - including the ordinary case of this host being off, which is why the
  receiver's grace period has to exceed the nightly off-window. It closes the structural gap
  measured on 2026-08-14, where `PostgreSQLBackupStale` could not see three backup-free days because
  Prometheus runs on the host that was off. Routing is in
  [`alertmanager.yml.example`](../../docker/monitoring/alertmanager/alertmanager.yml.example); the
  receiver itself is not provisioned yet

## Failure / Dependency Notes

Monitoring should start independently of application services and storage mounts where possible.
Dependencies must degrade gracefully without blocking the monitoring stack.

## Withdrawn targets

| Target | Removed | Why |
|---|---|---|
| `node-lxc240-vaultwarden`, `vaultwarden` HTTPS probe | 2026-09-01 | Service decommissioned and the guest stopped ([decision](../decisions/vaultwarden-decommission.md)). Removed in the same change as the shutdown: a scrape kept against a node that is off by design leaves `NodeDown` firing permanently |
