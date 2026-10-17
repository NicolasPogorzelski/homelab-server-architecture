# Runbook: Nextcloud MariaDB automated backup (mariadb-dump)

- **Use when:** deploying or redeploying the lxc210 backup, provisioning its share, running a dump by
  hand, or `MariaDBBackupStale` / `DatabaseBackupMetricsMissing` fires.
- **Duration:** 10 minutes for the role; 30 minutes including share provisioning.
- **Risk:** low; the procedure writes a new dump and never touches the database. Binding a share
  that is not mounted sends dumps to the container rootfs on the boot SSD (KE-7 class).
- **Last exercised:** 2026-08-15, pass (share provisioned, role deployed, manual run verified). The
  dump itself runs daily by timer.

Nextcloud on lxc210 runs its own MariaDB; the `pg_dumpall` on lxc260 does not cover it. Its user
files are on the vm102 archive pool, its database on the boot SSD
([KE-14](../../docs/platform/known-errors.md#ke-14)); without the database the files are unusable.

The [`mariadb_backup`](../../ansible/roles/mariadb_backup/) role deploys
`snippets/mariadb/mariadb-backup.sh` to `/usr/local/sbin/mariadb-backup.sh`, plus
`mariadb-backup.service` and `mariadb-backup.timer` (schedule in the role defaults,
`Persistent=true`, `RandomizedDelaySec`). It mirrors [pg-backup.md](pg-backup.md).

| Parameter | Value |
|---|---|
| Tool | `mariadb-dump --all-databases --single-transaction --routines --triggers --events`, gzip |
| Write | to `*.sql.gz.partial`, renamed only after verification passes |
| Verification | non-empty; `gzip -t`; exactly one `-- Dump completed on` marker |
| Retention | `-mtime +7` on `mariadb_all_*.sql.gz` and `*.sql.gz.partial`, only after verification |
| Auth | root over the unix socket (`unix_socket` plugin, no password stored) |
| Metric | `mariadb_backup_last_success_timestamp` in the node_exporter textfile directory |
| Target | `/mnt/backups` in lxc210 = host `/mnt/smb/db-backups` = `//vm102/DB-Backups` |

## Preconditions

The role asserts that `/mnt/backups` is a CIFS mount and refuses to deploy otherwise. The share and
the two mounts below are not managed by any role and are provisioned by hand once.

- vm102 exports `[DB-Backups]` (stanza in `snippets/storage/smb.conf.storage-vm102.sanitized.conf`;
  the directory is created by `storage_permissions`).
- The host mounts it at `/mnt/smb/db-backups` with `x-systemd.automount`
  ([KE-15](../../docs/platform/known-errors.md#ke-15)).
- lxc210 binds it: `mp1: /mnt/smb/db-backups,mp=/mnt/backups`.
- `node_exporter_textfile_dir` is set in `host_vars/lxc210.yml`.
- The Ansible control node (lxc250) reaches lxc210.

## Steps

1. Provision the share (only if `pct exec 210 -- findmnt -no FSTYPE /mnt/backups` does not print
   `cifs`). On vm102: add the `[DB-Backups]` stanza to `/etc/samba/smb.conf`, then
   `sudo testparm -s && sudo systemctl reload smbd`.
   Check: `testparm -s` parses without errors and lists `[DB-Backups]`.

2. Mount it on the host. Copy the existing postgres-backups line in `/etc/fstab` (Tailscale address
   of vm102, `x-systemd.automount`, `uid=100000,gid=100000` for root in an unprivileged container)
   and adjust share and mount point.
   ```bash
   mkdir -p /mnt/smb/db-backups
   systemctl daemon-reload
   systemctl start "$(systemd-escape -p --suffix=automount /mnt/smb/db-backups)"
   findmnt -no FSTYPE,SOURCE /mnt/smb/db-backups
   ```
   Check: `cifs //<vm102>/DB-Backups`. `daemon-reload` generates the automount unit but does not
   start it; without the `start` line nothing is mounted. Stop here unless the check passes.

3. Bind it into lxc210 and restart the container.
   ```bash
   pct set 210 -mp1 /mnt/smb/db-backups,mp=/mnt/backups
   pct reboot 210
   ```
   Check: `pct exec 210 -- findmnt -no FSTYPE /mnt/backups` prints `cifs`. A container started
   while the host mount was down keeps the empty directory; `pct reboot` is required.

4. Deploy the role, dry run first (from the repository's `ansible/` directory on lxc250).
   ```bash
   ansible-playbook playbooks/mariadb-backup.yml --check --diff
   ansible-playbook playbooks/mariadb-backup.yml
   ```
   Check: the assert reports `/mnt/backups is a CIFS mount`; a second run reports `changed=0`.

5. Confirm the timer is armed.
   ```bash
   pct exec 210 -- systemctl list-timers mariadb-backup.timer
   ```
   Check: a `NEXT` time is shown.

6. Run a dump on demand.
   ```bash
   pct exec 210 -- systemctl start mariadb-backup.service
   pct exec 210 -- journalctl -u mariadb-backup.service -n 5 --no-pager
   ```
   Check: last line `OK: /mnt/backups/mariadb_all_<ts>.sql.gz (<size>), gzip and completion marker verified`.

## Verification

Check one dump at a time; a glob over several files sums their markers.

```bash
pct exec 210 -- bash -c 'ls -1t /mnt/backups/mariadb_all_*.sql.gz | head -3; ls /mnt/backups/*.partial 2>/dev/null'
DUMP=/mnt/backups/mariadb_all_<ts>.sql.gz
pct exec 210 -- gzip -t "$DUMP"
pct exec 210 -- bash -c "gzip -cd $DUMP | grep -c '^-- Dump completed on '"
pct exec 210 -- cat /var/lib/node_exporter/textfile_collector/mariadb_backup.prom
```

Expected: a new dump, no `.partial` file, `gzip -t` exit 0, marker count `1`, a current timestamp in
the metric file. In Prometheus, `mariadb_backup_last_success_timestamp` (job
`node-lxc210-nextcloud`) has advanced and `MariaDBBackupStale` is not firing.

Verified 2026-08-15: playbook `changed=4` then `changed=0`; manual run `Result=success`, journal
`OK: /mnt/backups/mariadb_all_20260815_124422.sql.gz (2.2M), gzip and completion marker verified`;
`gzip -t` clean, one marker, 209 `CREATE TABLE` statements; metric scraped by Prometheus.

## Failure modes

| Symptom | Cause | Action |
|---|---|---|
| Role assert fails: not a CIFS mount | Share, fstab entry or bind missing | Steps 1-3. Do not create `/mnt/backups` by hand |
| `is not a CIFS mount` in the journal | Host mount dropped after deployment | Check the host automount unit, then `pct reboot 210` (KE-15) |
| `dump is empty` | MariaDB not running | `pct exec 210 -- systemctl status mariadb` |
| `fails the gzip integrity check` | Write interrupted or share full | `df -h /mnt/backups`; check `ArchivePoolLowSpace` |
| `completion markers, expected 1` | `mariadb-dump` died mid-write | `.partial` kept as evidence; MariaDB error log; older dumps are intact |
| `MariaDBBackupStale` | No verified dump for 25 h of uptime | Step 6; the rule cannot see time the host was off |
| No alert and no dumps | Metric never written, series absent | `DatabaseBackupMetricsMissing` should fire; check `node_exporter_textfile_dir` for lxc210 |
| Restore transcodes file names | Connection charset changed | The script pins `--default-character-set=utf8mb4`; keep it |

## Rollback

The role deploys a script, two units and a textfile directory; none of it touches the database.

```bash
pct exec 210 -- systemctl disable --now mariadb-backup.timer
pct exec 210 -- rm /etc/systemd/system/mariadb-backup.service /etc/systemd/system/mariadb-backup.timer
pct exec 210 -- systemctl daemon-reload
```

Provisioning in reverse order: `pct set 210 -delete mp1 && pct reboot 210`; `umount
/mnt/smb/db-backups`, remove the fstab line, `systemctl daemon-reload`; on vm102 remove the
`[DB-Backups]` stanza and reload smbd. Leave the dumps on the share.

## Background

A systemd timer because the host powers down nightly (`homelab_schedule`): `Persistent=true` runs
the overdue dump at the next boot. After a power-down both database timers catch up within seconds;
`RandomizedDelaySec` spreads them without ordering one unit after the other.

Root over the unix socket avoids a stored credential; a dedicated backup account would need one on
the node, in the vault and in a rotation schedule. Retention is 7 days, not 7 dumps: on a host that
sleeps, a quiet week leaves fewer files than days.

Restore: [mariadb-restore.md](mariadb-restore.md). Restorability is tested monthly by
`mariadb_restore_test`.
