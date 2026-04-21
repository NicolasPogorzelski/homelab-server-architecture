# Runbook: PostgreSQL automated backup (pg_dumpall)

## Problem

Without automated backups, a PostgreSQL failure (corruption, misconfiguration, accidental DROP)
results in complete data loss for all dependent services.

## Solution (CT260)

Automated daily `pg_dumpall` dump with gzip compression, stored on SMB (MergerFS).
Runtime data and backups reside on separate failure domains.

## Preconditions

- CT260 is running and PostgreSQL is online
- `/mnt/backups/` is mounted (SMB via mp1 on MergerFS)
- `postgres` user can write to `/mnt/backups/`
- Script deployed at `/usr/local/sbin/pg-backup.sh` (owner `root:postgres`, mode 750)
- For backup staleness alerting: Node Exporter on CT260 must have the textfile collector enabled
  (`--collector.textfile.directory=/var/lib/node_exporter/textfile_collector`) and the directory
  must exist and be writable by the `postgres` user

## Implementation

Repo snippet (source of truth):

- Script: [pg-backup.sh](../../snippets/postgres/pg-backup.sh)

### Configuration

| Parameter | Value |
|---|---|
| Tool | `pg_dumpall` (all databases + roles) |
| Schedule | daily 03:00 (crontab, `postgres` user) |
| Compression | gzip |
| Target | `/mnt/backups/` (SMB on MergerFS) |
| Retention | 7 days (`find -mtime +7 -delete`) |
| Auth | peer (no password, local socket) |

### Install steps (CT260)

1) Deploy script
```bash
install -m 0750 -o root -g postgres /dev/null /usr/local/sbin/pg-backup.sh
nano /usr/local/sbin/pg-backup.sh
```

Script content: see `snippets/postgres/pg-backup.sh`

2) Install crontab
```bash
echo "0 3 * * * /usr/local/sbin/pg-backup.sh" | crontab -u postgres -
```

---

## Verification
```bash
# Check crontab
crontab -u postgres -l

# Manual test run
su - postgres -c '/usr/local/sbin/pg-backup.sh'

# Inspect backup directory
ls -la /mnt/backups/

# Validate dump content (expect SQL header + CREATE ROLE statements)
zcat /mnt/backups/pg_dumpall_<timestamp>.sql.gz | head -20
```

---

## Failure Modes

| Symptom | Likely Cause | Action |
|---|---|---|
| Script exits with "Backup directory does not exist" | SMB mount missing | Check `findmnt /mnt/backups`, verify VM102 Samba |
| Empty dump file | PostgreSQL not running | Check `pg_isready`, inspect PG logs |
| Permission denied | Script ownership wrong | Verify `root:postgres` and mode 750 |
| Cron not firing | Crontab missing or cron daemon stopped | `crontab -u postgres -l`, `systemctl status cron` |
| Stale backups (no recent files) | Cron failure or silent script error | Check `/var/log/syslog` for cron entries |

---

## Restore (high-level)
```bash
# Stop all dependent services first
# Then restore into a running PostgreSQL instance:
zcat /mnt/backups/pg_dumpall_<timestamp>.sql.gz | psql -U postgres

# Verify roles and databases:
psql -U postgres -c '\du'
psql -U postgres -c '\l'
```

Full restore procedure: [pg-restore.md](pg-restore.md)

---

## Notes

- `pg_dumpall` is used (instead of per-DB `pg_dump`) because global objects (roles, passwords) must be included for full recovery.
- Per-database `pg_dump` will be added once multiple consumers exist (enables selective restore).
- Backup monitoring (alert on missing/stale dumps) is a planned improvement.
