# Runbook: Nextcloud MariaDB restore from a nightly dump

- **Use when:** Nextcloud's database on lxc210 is lost or corrupt, or has to be returned to a point
  before a bad change.
- **Duration:** 20-40 minutes.
- **Risk:** the restore overwrites the live `nextcloud` database; every write since the dump is lost.
  An import that stops partway leaves a mix of old and new tables.
- **Last exercised:** never against the live database. The non-destructive restore test runs
  monthly by timer (`mariadb_restore_test`) and first passed 2026-10-10.

Nextcloud's user files are on the vm102 archive pool; the database maps every blob to an owner, a
name and a path. The dump is a `mariadb-dump --all-databases` written by
`snippets/mariadb/mariadb-backup.sh` ([mariadb-backup.md](mariadb-backup.md)).

Run every command inside lxc210 as root (`pct enter 210`). The MariaDB client authenticates as root
over the unix socket; no password file is involved. `occ` runs as the web server user:

```bash
OCC="runuser -u www-data -- php /var/www/nextcloud/occ"
```

## Preconditions

- `findmnt -no FSTYPE /mnt/backups` prints `cifs`. An empty directory on the container rootfs
  passes `ls` ([KE-15](../../docs/platform/known-errors.md#ke-15)).
- MariaDB is running: `systemctl is-active mariadb` prints `active`.
- Free space on the lxc210 rootfs for one compressed dump of `nextcloud` (the safety copy, step 4).

## Steps

1. Select the dump.
   ```bash
   ls -1t /mnt/backups/mariadb_all_*.sql.gz | head -5
   DUMP=/mnt/backups/mariadb_all_<timestamp>.sql.gz
   ```
   Take the newest unless restoring to a point before a known bad change. Files without
   `.partial` passed the backup script's checks.
   Check: `$DUMP` exists and is not a `.partial` file.

2. Prove the file before touching the live database.
   ```bash
   gzip -t "$DUMP"
   gzip -cd "$DUMP" | grep -c '^-- Dump completed on '
   ```
   Check: `gzip -t` exits 0; the marker count is exactly `1`. Otherwise pick an older dump.

3. Stop writes.
   ```bash
   $OCC maintenance:mode --on
   systemctl stop apache2
   ```
   Check: `systemctl is-active apache2` prints `inactive`.

4. Take a safety dump of the live database. This makes step 5 reversible.
   ```bash
   SAFETY=/root/nextcloud-pre-restore-$(date +%Y%m%d_%H%M%S).sql.gz
   mariadb-dump --single-transaction --default-character-set=utf8mb4 --databases nextcloud | gzip > "$SAFETY"
   ```
   Check: `gzip -cd "$SAFETY" | grep -c '^-- Dump completed on '` prints `1`. Do not continue if
   this step failed. The copy stays off `/mnt/backups` so it is reachable if the share is the
   fault; move it off the node after the restore.

5. Restore.
   ```bash
   gzip -cd "$DUMP" | mariadb --default-character-set=utf8mb4
   ```
   The dump carries its own `CREATE DATABASE` and `USE` statements, plus the `mysql` database with
   users and grants. Do not add `--one-database`: it filters by the `USE` statements in the stream
   and would discard what this step needs.
   Check: `mariadb` exits 0 with no `ERROR` line.

6. Bring the service back.
   ```bash
   systemctl start apache2
   $OCC maintenance:mode --off
   $OCC status
   ```
   Check: `installed: true`, `maintenance: false`.

## Verification

```bash
mariadb --batch --skip-column-names -e \
  "SELECT count(*) FROM nextcloud.oc_storages;
   SELECT count(*) FROM nextcloud.oc_mounts;
   SELECT count(*) FROM nextcloud.oc_filecache;"
```

All three counts are non-zero. These are the tables the monthly test asserts: an import that left
them empty still exits 0, and without them Nextcloud serves nothing.

Then open one file through the web interface. The database can be complete while the storage
mapping points at a mount the container cannot reach; only a real read shows that.

## Failure modes

| Symptom | Cause | Action |
|---|---|---|
| `ERROR 1045 access denied` | Client not run as root, so the unix socket login does not apply | Run as root inside lxc210 |
| Import stops partway | Bad dump section or share dropped mid-read | Rollback, then retry with an older dump |
| `Table doesn't exist` in verification | Dump restored under another database name | `SHOW DATABASES;`; compare with `dbname` in `config/config.php` |
| `occ status` still reports maintenance | Step 3 set the flag in `config/config.php`; the dump does not carry it | `$OCC maintenance:mode --off` |
| Files listed but not downloadable | Storage mount, not the database | Check the CIFS bind (KE-15) |

## Rollback

Restore the safety copy from step 4:

```bash
$OCC maintenance:mode --on
systemctl stop apache2
gzip -cd /root/nextcloud-pre-restore-<timestamp>.sql.gz | mariadb --default-character-set=utf8mb4
systemctl start apache2
$OCC maintenance:mode --off
```

Before step 5 nothing live has changed: start Apache and turn maintenance mode off. Without the
step 4 copy the only way back is an older dump from the share.

## Background

`mariadb-restore-test.timer` (role `mariadb_restore_test`, schedule in its defaults) selects the
newest dump older than five minutes, checks gzip and the completion marker, imports the `nextcloud`
section into the throwaway database `restoretest_scratch` beside the live one, asserts the three
tables above are non-empty, and drops the throwaway on every exit path. It refuses to start if
`restoretest_scratch` already exists, because its cleanup drops that name. It never touches
`nextcloud`. A pass writes `mariadb_restore_test_last_success_timestamp`; `MariaDBRestoreTestStale`
fires after 40 days without one, `DatabaseBackupMetricsMissing` if the metric was never written.

Run it by hand before relying on a dump in an incident:

```bash
systemctl start mariadb-restore-test.service
journalctl -u mariadb-restore-test.service -n 30 --no-pager
```

Verified 2026-10-10: started through the unit by hand, it passed and wrote the metric.
