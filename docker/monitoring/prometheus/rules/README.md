# Prometheus Rules

This directory contains Prometheus alerting rules loaded via `rule_files` in `prometheus.yml`.

Active rules (`alert.rules.yml`):
- `NodeDown` — target unreachable for >2m (critical)
- `DiskSpaceCritical` — filesystem <15% free for >5m (warning)
- `HighMemoryUsage` — memory >90% for >5m (warning)
- `PostgreSQLBackupStale` — no successful pg_dumpall in >25h (warning; requires textfile collector on CT260)

Planned (`smart` group, not yet implemented):
- SMART disk health alerts — requires `smartctl_exporter` on VM102
