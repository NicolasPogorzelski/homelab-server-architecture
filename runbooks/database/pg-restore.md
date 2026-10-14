# Runbook: PostgreSQL restore from pg_dumpall backup

- **Use when:** a database on lxc260 is corrupted or lost, or lxc260 itself has to be rebuilt.
- **Duration:** 30-60 minutes for one database; longer for a full cluster.
- **Risk:** dropping the live database destroys every write since the dump; replaying the whole
  dump over a live cluster also touches the databases that were not meant to be restored.
- **Last exercised:** 2026-08-13, pass (full-cluster restore into a scratch cluster, all databases
  and roles compared against live). Validation runs monthly by timer (`postgresql_restore_test`).

The backup is a `pg_dumpall` of the whole cluster (all databases plus roles), written by
`snippets/postgres/pg-backup.sh`. It cannot be replayed for one database alone. This runbook has two
paths:

- **Path A (one database):** restore the dump into a scratch cluster on port 5433, `pg_dump` the one
  database out of it, and load that into the live cluster.
- **Path B (full cluster):** replay the whole dump into an empty cluster, with every consumer stopped.

Consumers: `openwebui_db` -> OpenWebUI on lxc230 (`/opt/openwebui/`); `paperless_db` -> Paperless-ngx
on lxc211 (`/opt/paperless/`). All commands run on the Proxmox host.

## Preconditions

- lxc260 is running; `/mnt/backups` inside it is the CIFS mount of the backup share.
- The dump to restore is known (timestamp in the file name).
- Free space on the backup share for one database dump plus one safety dump.

## Steps

### Path A: restore one database

1. Select the dump and confirm it is complete.
   ```bash
   pct exec 260 -- findmnt -no FSTYPE /mnt/backups
   pct exec 260 -- bash -c 'ls -1t /mnt/backups/pg_dumpall_*.sql.gz | head -5'
   DUMP=/mnt/backups/pg_dumpall_<timestamp>.sql.gz
   pct exec 260 -- gzip -t "$DUMP"
   pct exec 260 -- bash -c "gzip -cd $DUMP | grep -c 'PostgreSQL database cluster dump complete'"
   ```
   Check: `cifs`; `gzip -t` exits 0; the marker count is exactly `1`. Otherwise pick an older dump.

2. Create a scratch cluster and restore the whole dump into it.
   ```bash
   pct exec 260 -- pg_createcluster 15 restoretest --port 5433 --locale en_US.UTF-8 --start-conf manual
   pct exec 260 -- pg_ctlcluster 15 restoretest start
   pct exec 260 -- bash -c "gzip -cd $DUMP | runuser -u postgres -- psql -p 5433 -q -d postgres"
   ```
   Check: `pct exec 260 -- ss -tlnp | grep 5433` shows loopback only; the only `ERROR:` line from
   psql is `role "postgres" already exists`. Every command against the scratch cluster carries
   `-p 5433`.

3. Extract the one database from the scratch cluster.
   ```bash
   pct exec 260 -- bash -c "runuser -u postgres -- pg_dump -p 5433 -Fc <db> > /mnt/backups/restore_<db>.dump"
   ```
   Check: `pct exec 260 -- runuser -u postgres -- pg_restore -l /mnt/backups/restore_<db>.dump | head`
   lists tables of `<db>`.

4. Stop the consumer of `<db>`.
   ```bash
   pct exec 230 -- docker stop openwebui      # openwebui_db
   pct exec 211 -- docker stop paperless      # paperless_db
   ```
   Check: `pct exec <ctid> -- docker ps` no longer lists the container.

5. Take a safety dump of the current live state. This is what makes step 6 reversible.
   ```bash
   pct exec 260 -- bash -c "runuser -u postgres -- pg_dump -Fc <db> > /mnt/backups/pre-restore_<db>_$(date +%Y%m%d_%H%M%S).dump"
   ```
   Check: `pg_restore -l` on the file exits 0. Do not continue if this step failed.

6. Terminate remaining sessions and drop the live database.
   ```bash
   pct exec 260 -- runuser -u postgres -- psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '<db>' AND pid <> pg_backend_pid();"
   pct exec 260 -- runuser -u postgres -- dropdb <db>
   ```
   Check: `psql -l` no longer lists `<db>`.

7. Load the extracted database.
   ```bash
   pct exec 260 -- runuser -u postgres -- pg_restore -C -d postgres /mnt/backups/restore_<db>.dump
   pct exec 260 -- runuser -u postgres -- psql -d <db> -c 'ANALYZE;'
   ```
   Check: `psql -l` lists `<db>` with its original owner; `\du` shows the tenant role.

8. Start the consumer again.
   ```bash
   pct exec <ctid> -- docker start <container>
   ```
   Check: `docker ps` shows the container `Up (healthy)` or `Up`; `pg_stat_activity` on lxc260 shows a
   session for `<db>`.

9. Remove the scratch cluster and return its blocks to the thin pool.
   ```bash
   pct exec 260 -- pg_dropcluster 15 restoretest --stop
   pct fstrim 260
   ```
   Check: `pct exec 260 -- pg_lsclusters` lists only `main`.

### Path B: full cluster (lxc260 rebuilt or cluster lost)

1. Run step 1 of Path A.
2. Stop both consumers (step 4 of Path A, both lines).
   Check: neither `openwebui` nor `paperless` is running.
3. If the old cluster still starts, take a safety `pg_dumpall` of it to the backup share.
   Check: the file ends with the completion marker.
4. Provide an empty cluster: rebuild lxc260 per [docs/nodes/lxc260.md](../../docs/nodes/lxc260.md) or
   `pg_dropcluster 15 main --stop && pg_createcluster 15 main --start`. Do not run
   `postgresql_provisioning` before the restore; it would create the tenant databases empty and the
   dump's `CREATE DATABASE` statements would fail.
   Check: `psql -l` lists only `postgres`, `template0`, `template1`.
5. Replay the dump: `gzip -cd $DUMP | runuser -u postgres -- psql -q -d postgres`.
   Check: the only `ERROR:` is `role "postgres" already exists`.
6. Run the Ansible playbooks for lxc260 (`postgresql-provisioning.yml`, `pg-backup.yml`,
   `pg-restore-test.yml`, `postgres-exporter.yml`) to restore `pg_hba.conf`, timers and exporter.
   Check: the playbooks report no failed tasks; `systemctl list-timers 'pg-*'` shows both timers.
7. Start both consumers. Check: as step 8 of Path A, for both databases.

## Verification

- Exact row counts on the key tables, not `n_live_tup` (that is a statistics estimate and reads 0
  until `ANALYZE`):
  ```bash
  pct exec 260 -- runuser -u postgres -- psql -d paperless_db -tAc 'SELECT count(*) FROM documents_document;'
  pct exec 260 -- runuser -u postgres -- psql -d openwebui_db -tAc 'SELECT count(*) FROM migratehistory;'
  ```
- The application works for a user: log in, open a recent document or chat.
- `systemctl start pg-backup.service` on lxc260 succeeds afterwards.

## Failure modes

| Symptom | Cause | Action |
|---|---|---|
| `dropdb` fails: "being accessed by other users" | A consumer is still connected | Repeat step 4 and the terminate query |
| `CREATE DATABASE` fails on the scratch cluster | `--locale` differs from the live cluster | Match `SELECT datcollate FROM pg_database` |
| `pg_restore -C` fails: database exists | Step 6 did not complete | Drop it, rerun step 7 |
| Restored tables empty | Truncated or wrong dump | Recheck the marker; choose another dump |
| App cannot connect after Path B | `pg_hba.conf` not re-provisioned | Run step 6 of Path B |

## Rollback

- Before step 6 of Path A, nothing live has changed: start the consumer and drop the scratch cluster.
- After step 6: drop `<db>` again and load the safety dump from step 5 with
  `pg_restore -C -d postgres /mnt/backups/pre-restore_<db>_<ts>.dump`.
- Path B: restore the safety `pg_dumpall` from step 3 into an empty cluster the same way.
- Keep safety dumps until the restored service has been used, not only counted. They are not covered
  by the 7-day retention glob, so delete them by hand afterwards.

## Background

`pg_dumpall` output is one SQL stream for every database and role. Dropping one database and piping
the whole stream into `psql` recreates that database but also re-runs statements against the others,
which fail or duplicate data. Extracting via a scratch cluster yields a clean per-database custom
dump that `pg_restore -C` can load.

The backup script verifies each dump before publishing it (`gzip -t` and exactly one completion
marker), and `pg-restore-test.sh` restores the newest dump into the same scratch-cluster shape every
month; `PostgreSQLRestoreTestStale` fires after 40 days without a pass. See
[pg-backup.md](pg-backup.md) and [postgresql-platform.md](../../docs/services/postgresql-platform.md).

Verified 2026-08-13: full restore of `pg_dumpall_20260813_085331.sql.gz` into a scratch cluster;
`openwebui_db` matched live on 43 of 43 tables, `paperless_db` on 70 of 72 (the two differences were
rows created after the dump); all four roles identical; live cluster untouched.
