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
7. Re-apply `ansible-playbook playbooks/pg-backup.yml` — this redeploys `pg-backup.sh`,
   `pg-backup.service` and `pg-backup.timer`. There is no cron entry to restore.

Refer to: [postgresql-platform.md](../../docs/services/postgresql-platform.md) for hardening details.

---

## Non-destructive verification (use this for scheduled tests)

The procedure above is the **recovery** path: it drops a live database, so it can only be
rehearsed by accepting an outage. For periodic *validation* — proving that the dumps on disk are
restorable — restore into a throwaway cluster instead. Nothing live is touched, no service is
stopped, and it exercises the **full-cluster** path (all databases plus roles), which the
single-DB procedure does not.

### 1. Verify the dump is readable and complete

```bash
DUMP=$(pct exec 260 -- bash -c 'ls -1t /mnt/backups/pg_dumpall_*.sql.gz | head -1')
pct exec 260 -- gzip -t "$DUMP"                                       # exit 0 = not truncated
pct exec 260 -- bash -c "gunzip -c $DUMP | grep -c 'cluster dump complete'"   # must be 1
```

`pg_dumpall` writes `-- PostgreSQL database cluster dump complete` as its final line. Its
presence is what distinguishes a finished dump from one that died mid-write; `gzip -t` alone
does not, because a truncated stream can still be a valid gzip member. **The backup script
performs neither check** — it tests only that the file is non-empty.

### 2. Create a throwaway cluster

```bash
pct exec 260 -- pg_createcluster 15 restoretest --port 5433 \
    --locale en_US.UTF-8 --start-conf manual
pct exec 260 -- pg_ctlcluster 15 restoretest start
```

`--locale` must match the live cluster (`SELECT datcollate FROM pg_database`) or the dump's
`CREATE DATABASE … LC_COLLATE` statements fail. `--start-conf manual` is deliberate: if cleanup
is interrupted, the stray cluster will not come back at the next boot.

Confirm it binds loopback only — a second cluster must not appear on the tailnet:

```bash
pct exec 260 -- ss -tlnp | grep 5433     # expect 127.0.0.1:5433 and [::1]:5433 only
```

### 3. Restore into it

```bash
pct exec 260 -- su -s /bin/bash -c \
    "cd /tmp && gunzip -c $DUMP | psql -p 5433 -q -d postgres" postgres
```

Every command carries `-p 5433`. That port is the only thing separating a validation run from
overwriting production.

### 4. Compare against the live cluster

Compare **exact** counts, not `n_live_tup` from `pg_stat_user_tables` as step 6 of the recovery
procedure does — that column is a statistics estimate and reads 0 on a freshly restored cluster
until `ANALYZE` runs, which looks like total data loss and is not.

```sql
SELECT relname,
       (xpath('/row/cnt/text()',
              query_to_xml(format('SELECT count(*) AS cnt FROM %I.%I', schemaname, relname),
                           false, true, '')))[1]::text::bigint AS n
FROM pg_stat_user_tables ORDER BY relname;
```

Run it against port 5432 and 5433 per database and `diff` the output. Also diff `pg_roles`.

**Expect append-only tables to differ.** The live database keeps moving after the dump was
taken, so queue and task-log tables will show *more* rows live than restored. That is the
correct result, not a defect — confirm it by checking that the surplus rows carry timestamps
**after** the dump, rather than assuming it.

### 5. Remove it and reclaim the space

```bash
pct exec 260 -- pg_dropcluster 15 restoretest --stop
pct exec 260 -- pg_lsclusters                       # only 'main' must remain
pct fstrim 260                                      # on the Proxmox host
```

The restored data occupies thin-pool blocks on the boot SSD. Dropping the cluster frees the
filesystem, but only `fstrim` returns the blocks to the pool — see
[LVM thin pool full](../platform/lvm-thin-pool-full.md).

---

## Verification

| Date | Scope | Result |
|---|---|---|
| 2026-08-13 | **Full-cluster** restore of `pg_dumpall_20260813_085331.sql.gz` into a throwaway cluster on port 5433; both databases and all roles compared against live | Pass — see below |
| 2026-04-04 | Single-DB restore (openwebui_db): drop → restore → app reconnect | Pass |

**2026-08-13 detail.** Dump 44,065 lines / 139 MB uncompressed, `gzip -t` clean, completion
marker present. Restore exited 0 with exactly one error — `role "postgres" already exists`, the
harmless case already listed under Failure Modes. `openwebui_db` matched live exactly (43/43
tables). `paperless_db` matched on **70 of 72** tables; the two differences were
`django_celery_results_taskresult` (−10) and `documents_paperlesstask` (−2), both accounted for
by rows created after the dump timestamp (verified: latest post-dump rows at 09:30 and 09:05 UTC
against a dump at 08:53:31). All four roles restored identically. Functional read on restored
data: 2,648 documents spanning 1906-04-01 to 2026-05-07. Live cluster untouched throughout —
same backend PID before and after, no restart, no failed unit. Thin pool 81.76 % before and
after (152 MiB reclaimed by `fstrim`).

---

## Related Documents

- [pg-backup.md](pg-backup.md) — Backup procedure
- [postgresql-platform.md](../../docs/services/postgresql-platform.md) — Platform service documentation
- [pg-backup.sh](../../snippets/postgres/pg-backup.sh) — Backup script
