# Runbook: PostgreSQL restore from pg_dumpall backup

## Problem

A PostgreSQL database must be restored from backup after corruption,
accidental deletion, or CT260 rebuild.

## Preconditions

- CT260 is running and PostgreSQL is online
- `/mnt/backups/` is mounted and contains valid `pg_dumpall_*.sql.gz` dumps
- All dependent services (e.g. OpenWebUI on CT230) are stopped
- No active connections to the target database

## Procedure

All commands run on the Proxmox host via `pct exec`.

### 1. Identify the backup to restore
```bash
pct exec 260 -- ls -lt /mnt/backups/ | head -10
```

Select the appropriate dump file by timestamp.

### 2. Stop dependent services
```bash
# OpenWebUI (CT230)
pct exec 230 -- docker stop openwebui
```

### 3. Verify no active connections
```bash
pct exec 260 -- su -s /bin/bash -c "cd /tmp && psql -c \"
SELECT pid, usename, state FROM pg_stat_activity
WHERE datname = '<target_db>';\"" postgres
```

If connections remain, terminate them:
```bash
pct exec 260 -- su -s /bin/bash -c "cd /tmp && psql -c \"
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
WHERE datname = '<target_db>' AND pid <> pg_backend_pid();\"" postgres
```

### 4. Drop the target database
```bash
pct exec 260 -- su -s /bin/bash -c "cd /tmp && dropdb <target_db>" postgres
```

### 5. Restore from dump
```bash
pct exec 260 -- su -s /bin/bash -c "cd /tmp && gunzip -c /mnt/backups/<dump_file>.sql.gz | psql" postgres
```

Expected output:
- `CREATE DATABASE`, `CREATE TABLE`, `COPY`, `ALTER TABLE`, `CREATE INDEX` statements
- `ERROR: role "..." already exists` for pre-existing roles (harmless)

### 6. Verify restore
```bash
# Database exists with correct owner
pct exec 260 -- su -s /bin/bash -c "cd /tmp && psql -c '\l'" postgres

# Tables and row counts
pct exec 260 -- su -s /bin/bash -c "cd /tmp && psql -d <target_db> -c \"
SELECT schemaname, relname, n_live_tup
FROM pg_stat_user_tables
ORDER BY n_live_tup DESC
LIMIT 20;\"" postgres

# Roles intact
pct exec 260 -- su -s /bin/bash -c "cd /tmp && psql -c '\du'" postgres
```

### 7. Restart dependent services
```bash
pct exec 230 -- docker start openwebui

# Verify health
sleep 10
pct exec 230 -- docker ps --format "table {{.Names}}\t{{.Status}}"

# Verify DB connection
pct exec 260 -- su -s /bin/bash -c "cd /tmp && psql -c \"
SELECT pid, usename, state FROM pg_stat_activity
WHERE datname = '<target_db>';\"" postgres
```

---

## Failure Modes

| Symptom | Likely Cause | Action |
|---|---|---|
| `DROP DATABASE` fails: "being accessed by other users" | Active connections remain | Terminate via `pg_terminate_backend()` or stop all consumers |
| Restore errors: `role "X" already exists` | Role survived the drop (expected) | Harmless — `pg_dumpall` includes `CREATE ROLE` for all roles |
| Restore errors: `database "X" already exists` | Database was not dropped | Run `dropdb` first |
| Tables exist but row counts are zero | Wrong dump file selected | Check dump timestamp, try a different backup |
| App cannot connect after restore | pg_hba.conf or listen_addresses changed | Verify pg_hba rules and listen_addresses match pre-restore state |

---

## Full Cluster Restore (CT260 Rebuild)

If CT260 must be rebuilt from scratch:

1. Create new CT260 (Debian 12, unprivileged, same spec)
2. Install PostgreSQL 15
3. Configure `postgresql.conf` (listen_addresses, data-checksums)
4. Configure `pg_hba.conf` (service allowlist)
5. Mount backup share (`/mnt/backups`)
6. Run restore procedure (steps 5–7 above)
7. Re-enable backup cron

Refer to: [postgresql-platform.md](../../docs/services/postgresql-platform.md) for hardening details.

---

## Verification

| Date | Scope | Result |
|---|---|---|
| 2026-04-04 | Single-DB restore (openwebui_db): drop → restore → app reconnect | Pass |

---

## Related Documents

- [pg-backup.md](pg-backup.md) — Backup procedure
- [postgresql-platform.md](../../docs/services/postgresql-platform.md) — Platform service documentation
- [pg-backup.sh](../../snippets/postgres/pg-backup.sh) — Backup script
