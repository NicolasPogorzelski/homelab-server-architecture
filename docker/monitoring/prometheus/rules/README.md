# Prometheus Rules

This directory contains Prometheus alerting rules loaded via `rule_files` in `prometheus.yml`.

Active rules (`alert.rules.yml`):

`node` group:
- `NodeDown` - target unreachable for >2m (critical)
- `DiskSpaceCritical` - filesystem <15% free for >5m (warning). Excludes `cifs` (a remote view of
  storage another node owns), `fuse.mergerfs`, and the archive member disks - see the `storage`
  group.
- `HighMemoryUsage` - memory >90% for >5m (warning)
- `PostgreSQLBackupStale` - no successful pg_dumpall in >25h (warning; requires textfile collector on CT260)
- `MariaDBBackupStale` - no successful mariadb-dump in >25h (warning; requires textfile collector on CT210).
  Covers Nextcloud's own database, which the PostgreSQL dump never touched.

`postgres` group (requires `postgres_exporter` on CT260):
- `PostgreSQLDown` - `pg_up == 0` for >2m (critical)
- `PostgreSQLConnectionsHigh` - active connections >80% of `max_connections` for >5m (warning)

`storage` group:
- `ArchivePoolLowSpace` - MergerFS pool below 100 GiB absolute free for >1h (warning). The
  archive is meant to fill, so a percentage threshold is meaningless on multi-terabyte; what matters is
  whether the next write fits. Write consumers (Nextcloud, Paperless, Vaultwarden, `pg_dumpall`
  to `/mnt/backups`) hit `ENOSPC` long before read consumers notice.

`systemd` group (requires `node_exporter --collector.systemd`):
- `SystemdUnitFailed` - any unit in `failed` state for >15m (warning). No exception list: units
  that can never succeed on a node are masked or removed by the `systemd_hygiene` Ansible role.
  `.mount` units are in scope - node_exporter's stock `unit-exclude` drops them, and the fault
  this rule was written for (KE-15) is a mount fault.

Planned (`smart` group, not yet implemented):
- SMART disk health alerts - requires `smartctl_exporter` on the Proxmox host. All nine disks
  are attached there; VM102 sees only virtio-SCSI devices and cannot read SMART (see KE-14).
