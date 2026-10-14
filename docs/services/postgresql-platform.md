# PostgreSQL Platform Service

One PostgreSQL instance on lxc260 serves every application that needs PostgreSQL, with one database
and one role per tenant. Shared hardening, backup, restore testing and monitoring are done once
instead of per service ([DD-12](../decisions/design-decisions.md#dd-12)). Node details:
[lxc260](../nodes/lxc260.md).

## Tenants

| Service | Node | Database | User | ACL source | pg_hba |
|---|---|---|---|---|---|
| OpenWebUI | lxc230 | `openwebui_db` | `openwebui_user` | `tag:ai-stack` | `hostssl`, lxc230 `/32` |
| Paperless-ngx | lxc211 | `paperless_db` | `paperless_user` | host alias `paperless` | `hostssl`, lxc211 `/32` |

Nextcloud keeps MariaDB in lxc210 and Calibre-Web uses SQLite; neither is a tenant.

## Access Model

Four independent layers; a client must pass all of them.

1. **Tailscale ACL.** Only the sources in the table reach `tag:database:5432`; no workstation does
   ([tailscale-acl.md](../platform/tailscale-acl.md)).
2. **Bind.** `listen_addresses = '127.0.0.1, <tailscale-ip-lxc260>'`; nothing on `0.0.0.0` or the
   LAN. The start is gated on the Tailscale address ([KE-9](../platform/known-errors.md#ke-9)).
3. **`pg_hba.conf`.** One `hostssl` line per tenant, `scram-sha-256`, `/32` source; everything
   else rejected:

```
local   all            postgres                               peer
host    all            all             127.0.0.1/32           scram-sha-256
hostssl <service>_db   <service>_user  <tailscale-ip-lxc###>/32  scram-sha-256
host    all            all             0.0.0.0/0              reject
host    all            all             ::/0                   reject
```

4. **Roles.** Each tenant owns its database; `public` schema rights are revoked from `PUBLIC`. No
   shared credentials.

Client certificates (`clientcert=verify-full`) are not used.

## Service Onboarding Pattern

The `postgresql_provisioning` role (`ansible/playbooks/postgresql-provisioning.yml`) implements
steps 1 to 3: add the tenant to `postgres_tenants` in `host_vars/lxc260.yml` and its vaulted password
to `postgres_tenant_passwords`, then run the playbook. The two live tenants are not adopted into the
list yet, because the role re-asserts passwords.

1. Database and role, as `postgres` on lxc260:

```sql
CREATE DATABASE <service>_db;
CREATE USER <service>_user WITH PASSWORD '<strong-password>';
GRANT ALL PRIVILEGES ON DATABASE <service>_db TO <service>_user;
\c <service>_db
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT ALL ON SCHEMA public TO <service>_user;
```

2. The `hostssl` line above the reject block.
3. `systemctl reload postgresql`.
4. A Tailscale ACL grant to `tag:database:5432`, naming the host alias where the tag is shared.
5. A row in the tenant table above.

## Backup Strategy

| Item | Value |
|---|---|
| Tool | `pg_dumpall`, gzip, all databases and roles |
| Schedule | `pg-backup.timer`, nightly, `Persistent=true` (`postgresql_backup` defaults) |
| Target | `/mnt/backups`, the vm102 `[Postgres-backups]` share |
| Retention | `find -mtime +7`, so a dump is removed after 8 days |
| Script | `snippets/postgres/pg-backup.sh`, deployed by `postgresql_backup` |

- The script refuses to run unless `/mnt/backups` is a CIFS mount.
- It writes `<name>.sql.gz.partial` and renames it only after three checks: non-empty, `gzip -t`,
  and exactly one `PostgreSQL database cluster dump complete` marker. Only the marker catches a
  dump killed halfway, which is still a valid gzip stream.
- Checks run before the retention delete, so a failed run never removes the last good dump.
- Success writes `pg_backup_last_success_timestamp` for `PostgreSQLBackupStale`.
- The write-time checks read through the CIFS page cache. Durability on vm102 is proven by the
  monthly restore test (`postgresql_restore_test`), which restores the newest dump into a
  throwaway cluster on port 5433 ([pg-restore](../../runbooks/database/pg-restore.md)).

Prometheus runs on the same host, which powers down at night. A multi-day outage produces no
scrape and, at the next boot, a catch-up dump; `PostgreSQLBackupStale` therefore means "no more
than 25 hours of uptime without a dump", not "a dump every day".

Verify:

```bash
systemctl list-timers pg-backup.timer pg-restore-test.timer
journalctl -u pg-backup.service -n 30
ls -la /mnt/backups/
```

## Monitoring

- node_exporter on lxc260 and `postgres_exporter` on `<tailscale-ip-lxc260>:9187` (user
  `postgres_exporter`, role `pg_monitor`), both scraped by Prometheus on lxc200
- Alerts: `PostgreSQLDown`, `PostgreSQLConnectionsHigh`, `PostgreSQLBackupStale`,
  `PostgreSQLRestoreTestStale` and `DatabaseBackupMetricsMissing`; conditions are in
  [monitoring](../platform/monitoring.md)

## Durability

`fsync` and `synchronous_commit` stay on, and data checksums are enabled. The data directory is on
local block storage, never on CIFS; only dumps go to SMB.

## Failure Impact

- OpenWebUI and Paperless-ngx lose their database and do not start; open connections end.
- Committed data is safe while the data directory is intact. If it is lost, the newest verified
  dump on vm102 is the recovery point.
- Recovery order: lxc260, then the application containers.

## Open Items

- [Off-site backup](../platform/remediation-plan.md#off-site-backup) of the dumps
- [aux-disk replacement](../platform/remediation-plan.md#aux-disk-replacement-and-disposal), which
  holds the data directory ([KE-13](../platform/known-errors.md#ke-13))

## Related Documents

- [lxc260](../nodes/lxc260.md)
- [PostgreSQL backup runbook](../../runbooks/database/pg-backup.md)
- [PostgreSQL restore runbook](../../runbooks/database/pg-restore.md)
