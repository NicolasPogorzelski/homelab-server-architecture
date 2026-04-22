# Prometheus Rules

This directory contains Prometheus alerting rules loaded via `rule_files` in `prometheus.yml`.

Active rules (`alert.rules.yml`):

`node` group:
- `NodeDown` — target unreachable for >2m (critical)
- `DiskSpaceCritical` — filesystem <15% free for >5m (warning)
- `HighMemoryUsage` — memory >90% for >5m (warning)
- `PostgreSQLBackupStale` — no successful pg_dumpall in >25h (warning; requires textfile collector on CT260)

`postgres` group (requires `postgres_exporter` on CT260):
- `PostgreSQLDown` — `pg_up == 0` for >2m (critical)
- `PostgreSQLConnectionsHigh` — active connections >80% of `max_connections` for >5m (warning)

Planned (`smart` group, not yet implemented):
- SMART disk health alerts — requires `smartctl_exporter` on VM102
