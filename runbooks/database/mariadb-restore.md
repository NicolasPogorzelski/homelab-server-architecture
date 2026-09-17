# Runbook: Nextcloud MariaDB restore from a nightly dump

## Problem

Nextcloud's database is gone, corrupt, or has been rolled forward into a state
somebody needs undone. Its user files are on the archive pool and are almost
certainly intact; they are also unusable without this database, because the
index that maps a blob on disk back to an owner, a name and a path lives here
and nowhere else.

## Preconditions

- The dump is on the SMB share, bound into CT210 as `/mnt/backups`. Confirm the
  bind is the share and not an empty directory on the container rootfs:
  `findmnt -no FSTYPE /mnt/backups` must print `cifs`. A plain `ls` passes when
  the mount is absent, which is the [KE-15](../../docs/platform/known-errors.md#ke-15)
  failure class.
- Root on CT210, which is where `/root/.my.cnf` holds the credentials the client
  reads.
- Nextcloud is in maintenance mode, or Apache is stopped. Restoring underneath a
  running instance produces a database that disagrees with the sessions using it.

## Procedure

### 1. Select the dump

```bash
ls -lt /mnt/backups/mariadb_all_*.sql.gz | head -5
```

Take the newest unless you are restoring to a point before a known bad change.
The nightly job renames into place only after its own checks pass, so any file
present is complete.

### 2. Prove the file before touching the live database

```bash
gzip -t /mnt/backups/mariadb_all_<timestamp>.sql.gz
gzip -cd /mnt/backups/mariadb_all_<timestamp>.sql.gz | grep -c 'Dump completed'
```

`gzip -t` must exit 0 and the marker count must be exactly 1. A valid gzip of a
half-finished dump decompresses cleanly and imports into empty tables without an
error, which is the one failure neither size nor compression catches.

### 3. Put Nextcloud out of the way

```bash
occ maintenance:mode --on
systemctl stop apache2
```

### 4. Keep a way back

```bash
mariadb-dump --single-transaction --databases nextcloud \
  | gzip > /root/nextcloud-pre-restore-$(date +%Y%m%d_%H%M%S).sql.gz
```

Not on `/mnt/backups`: if the share is the problem you are restoring around, a
rollback copy written there is a rollback copy you cannot reach. Move it off the
node once the restore has succeeded.

### 5. Restore

```bash
gzip -cd /mnt/backups/mariadb_all_<timestamp>.sql.gz | mariadb
```

The dump carries its own `CREATE DATABASE` and `USE` statements. Do not add
`--one-database` here: that flag is for the monthly test, which confines the
stream to a throwaway database, and it would discard exactly the statements this
procedure needs.

## Verification

```bash
mariadb --batch --skip-column-names -e \
  "SELECT count(*) FROM nextcloud.oc_storages;
   SELECT count(*) FROM nextcloud.oc_mounts;
   SELECT count(*) FROM nextcloud.oc_filecache;"
```

All three must be non-zero. These are the three the monthly test asserts, for the
same reason: without them Nextcloud serves nothing, and an import that produced
empty versions of them returns exit code 0.

Then bring the service back and check it end to end:

```bash
systemctl start apache2
occ maintenance:mode --off
occ status
```

`occ status` must report `installed: true` and no maintenance mode. Open one file
through the web interface: the database can be complete while the storage
mapping points somewhere the container cannot reach, and only a real read shows
that.

## Failure

- **`ERROR 1045 access denied`** - the client is not reading `/root/.my.cnf`.
  Check you are root and that the file is `0600`; the client ignores it otherwise
  and says nothing about why.
- **Import stops partway** - the database is now half old and half new, which is
  worse than either. Restore the pre-restore copy from step 4 and start again.
- **`Table doesn't exist` during verification** - the dump restored into a
  different database name. Check with `SHOW DATABASES;` and look for a name from
  an older installation.
- **`occ status` reports maintenance mode after the restore** - the dump carried
  the flag. `occ maintenance:mode --off` again; the setting lives in the database,
  so a dump taken during maintenance restores it.
- **Files listed but not downloadable** - the database is fine and the storage
  mount is not. This runbook is finished; the fault is the CIFS bind, and
  [KE-15](../../docs/platform/known-errors.md#ke-15) is the entry that describes it.

## Rollback

Restore the copy written in step 4:

```bash
systemctl stop apache2
gzip -cd /root/nextcloud-pre-restore-<timestamp>.sql.gz | mariadb
systemctl start apache2
occ maintenance:mode --off
```

If step 4 was skipped there is no rollback, only an older dump from the share.
That is the reason step 4 is in the procedure and not in the notes.

## Non-destructive verification (automated since 2026-09-17)

`mariadb-restore-test.timer` runs on the 15th of each month at 09:00 local. It
selects the newest settled dump, checks the gzip and the completion marker,
restores into a throwaway database beside the live one, asserts the three tables
above are non-empty, and drops the throwaway on every exit path including
failure. It writes `mariadb_restore_test_last_success_timestamp`, which
`MariaDBRestoreTestStale` alerts on at 40 days.

It never touches `nextcloud`. The whole safety argument rests on one assertion at
the top of the script: the throwaway name must not already exist, because the
cleanup trap drops whatever that name refers to.

Run it by hand before relying on a dump in an incident:

```bash
systemctl start mariadb-restore-test.service
journalctl -u mariadb-restore-test.service -n 30 --no-pager
```
