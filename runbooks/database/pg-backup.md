# Runbook: PostgreSQL automated backup (pg_dumpall)

- **Use when:** deploying or redeploying the lxc260 backup, running a dump by hand, or
  `PostgreSQLBackupStale` / `DatabaseBackupMetricsMissing` fires.
- **Duration:** 10 minutes.
- **Risk:** low; the procedure writes a new dump and never touches the database.
- **Last exercised:** 2026-08-14, pass (role deployed, manual run verified). The dump itself runs
  daily by timer.

The [`postgresql_backup`](../../ansible/roles/postgresql_backup/) role deploys
`snippets/postgres/pg-backup.sh` to `/usr/local/sbin/pg-backup.sh`, plus `pg-backup.service` and
`pg-backup.timer` (schedule in the role defaults, `Persistent=true`). The script writes a
`pg_dumpall` of the whole cluster to `/mnt/backups` on lxc260, the CIFS share
`//vm102/Postgres-Backups`.

| Parameter | Value |
|---|---|
| Tool | `pg_dumpall` (all databases and roles), gzip |
| Write | to `*.sql.gz.partial`, renamed only after verification passes |
| Verification | non-empty; `gzip -t`; exactly one `cluster dump complete` marker |
| Retention | `-mtime +7` on `*.sql.gz` and `*.sql.gz.partial`, only after verification |
| Auth | peer (local socket, no password) |
| Metric | `pg_backup_last_success_timestamp` in the node_exporter textfile directory |

## Preconditions

- lxc260 is running and PostgreSQL is online.
- `/mnt/backups` is a CIFS mount: `pct exec 260 -- findmnt -no FSTYPE /mnt/backups` prints `cifs`.
- Ansible control node (lxc250) can reach lxc260.

## Steps

1. Deploy, dry run first (from the repository's `ansible/` directory on lxc250).
   ```bash
   ansible-playbook playbooks/pg-backup.yml --check --diff
   ansible-playbook playbooks/pg-backup.yml
   ```
   Check: the second run of the playbook reports `changed=0`.

2. Confirm the timer is armed.
   ```bash
   pct exec 260 -- systemctl list-timers pg-backup.timer
   ```
   Check: a `NEXT` time is shown.

3. Run a dump on demand.
   ```bash
   pct exec 260 -- systemctl start pg-backup.service
   pct exec 260 -- journalctl -u pg-backup.service -n 5 --no-pager
   ```
   Check: last line `OK: /mnt/backups/pg_dumpall_<ts>.sql.gz (<size>), gzip and completion marker verified`.

## Verification

```bash
pct exec 260 -- bash -c 'ls -1t /mnt/backups/pg_dumpall_*.sql.gz | head -3; ls /mnt/backups/*.partial 2>/dev/null'
pct exec 260 -- gzip -t /mnt/backups/pg_dumpall_<ts>.sql.gz
pct exec 260 -- bash -c "gzip -cd /mnt/backups/pg_dumpall_<ts>.sql.gz | grep -c 'PostgreSQL database cluster dump complete'"
```

Expected: a new dump, no `.partial` file, `gzip -t` exit 0, marker count `1`. In Prometheus,
`pg_backup_last_success_timestamp` has advanced and `PostgreSQLBackupStale` is not firing.

Verified 2026-08-14: playbook `changed=1` then `changed=0`; manual run printed
`OK: /mnt/backups/pg_dumpall_20260814_111738.sql.gz (41M), gzip and completion marker verified`; no
`.partial` left; metric scraped within 29 s.

## Failure modes

| Symptom | Cause | Action |
|---|---|---|
| `is not a CIFS mount` | Share missing on the host or vm102 down | Fix the host mount, then `pct reboot 260`; a bind set up while the mount was down does not heal (KE-15) |
| `dump is empty` | PostgreSQL not running | `pct exec 260 -- pg_isready`; PostgreSQL log |
| `fails the gzip integrity check` | Write interrupted or share full | `df -h /mnt/backups`; check `ArchivePoolLowSpace` |
| `completion markers, expected 1` | `pg_dumpall` died mid-dump | `journalctl -u pg-backup.service`; PostgreSQL log for OOM kill or connection drop |
| `.partial` file on the share, no new dump | Run failed verification | Older dumps are intact (retention runs after verification); diagnose from the messages above |
| Timer not firing | Timer disabled or unit failed | `systemctl status pg-backup.timer` |
| `PostgreSQLBackupStale` after a long power-off | Host was down; `Persistent=true` runs one catch-up at boot | Wait 15 minutes after boot, then step 3 |
| `DatabaseBackupMetricsMissing` | Prometheus scrapes an exporter that reads a different textfile directory | Check the node_exporter textfile path on lxc260 |

## Rollback

The role deploys a script, two units and a textfile directory; none of it touches the database.

```bash
pct exec 260 -- systemctl disable --now pg-backup.timer
pct exec 260 -- rm /etc/systemd/system/pg-backup.service /etc/systemd/system/pg-backup.timer
pct exec 260 -- systemctl daemon-reload
```

Leave the dumps on the share. Do not re-add a cron entry: the role removes the legacy one, and both
together would dump twice on nights the host stays up.

## Background

A systemd timer instead of cron because the host powers down nightly (`homelab_schedule`); a missed
cron slot is lost, while `Persistent=true` runs the overdue dump at the next boot and a failed unit
raises `SystemdUnitFailed`.

`pg_dumpall` carries roles and their passwords, which a per-database `pg_dump` leaves out and a
full recovery needs. Restoring a single database from it is covered in
[pg-restore.md](pg-restore.md). The dump is verified before publishing because `gzip -t` alone passes
a truncated dump that restores without errors and leaves empty tables. Restorability is tested monthly
by `postgresql_restore_test`; see [pg-restore.md](pg-restore.md).
