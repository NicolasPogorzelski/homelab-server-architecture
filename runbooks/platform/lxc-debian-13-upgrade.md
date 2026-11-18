# Runbook: Upgrade a Debian 12 LXC to Debian 13

- **Use when:** a container still runs Debian 12 (bookworm), which is in LTS and unsupported after
  2028-06-30.
- **Duration:** 5-10 minutes per container; the services in it are down for the reboot, about one
  minute.
- **Risk:** a package whose new major version needs its own migration (PostgreSQL, PHP, MariaDB)
  leaves the service stopped or misconfigured; on lxc250 the control node is unreachable while it
  reboots.
- **Last exercised:** 2026-11-18, pass (all seven containers; on lxc250 `pipx reinstall-all`
  failed and step 7 is the install that worked).

## Preconditions

- `/mnt/vzdump` is mounted on the hypervisor and has room for one archive of the container.
- Every third-party APT source has a `trixie` suite: `lxc-trixie-upgrade.sh <ctid> check` answers
  200 for each Release file.
- For lxc260 and lxc210, the nightly dump of the day exists on the backup share.

## Steps

1. Copy `snippets/scripts/lxc-trixie-upgrade.sh` to the hypervisor and run the check.
   Check: `lxc-trixie-upgrade.sh <ctid> check` lists the files that name bookworm and 200 for
   every Release file.
2. For lxc260, mark the running server version as installed by hand, so nothing removes it while
   its cluster still runs on it: `apt-mark manual postgresql-15 postgresql-client-15`.
3. For lxc210, put Nextcloud into maintenance mode:
   `sudo -u www-data php /var/www/nextcloud/occ maintenance:mode --on`.
4. Upgrade. Use `keep` on lxc210 and lxc260, which skips `autoremove`:
   `lxc-trixie-upgrade.sh <ctid> apply [keep]`. For lxc250 start it detached, because the
   Ansible run that would watch it runs on lxc250:
   `systemd-run --unit=trixie-250 --collect /bin/bash /root/lxc-trixie-upgrade.sh 250 apply keep`.
   Check: `Debian GNU/Linux 13 (trixie) | state running | failed:` with nothing after `failed:`,
   every Docker container `Up`, `pending after: 0`.
5. lxc260 only: take a fresh `pg_dumpall`, then `pg_upgradecluster -v 17 -m dump 15 main`, then
   apply `postgresql-boot-order.yml` so the Tailscale wait gates the new cluster unit.
   Check: `pg_lsclusters` shows 17 online on 5432 and 15 down on 5433; `datcollversion` equals
   `pg_database_collation_actual_version(oid)` in every database.
6. lxc210 only: run `snippets/scripts/nextcloud-php84.sh` in the container. It installs the PHP 8.4
   modules, carries the Nextcloud values over from the 8.2 `php.ini`, switches Apache's module and
   ends maintenance mode.
   Check: `php cli: 8.4.x`, `status.php` returns `"maintenance":false`.
7. lxc250 only: as `devops`, note the installed version with `pipx list --short` before step 4,
   then reinstall Ansible for the new Python: `pipx reinstall-all` for the other tools and
   `pipx install --include-deps ansible==<version>` for Ansible.
   Check: `ansible --version` names Python 3.13; `ansible all -m ping` answers from every node.

## Verification

- `ansible lxcs -m command -a 'grep VERSION_CODENAME /etc/os-release'` reports `trixie` on each
  upgraded container.
- `SystemdUnitFailed` and `ServiceDown` are quiet ten minutes after the last reboot.
- The next nightly dumps on lxc210 and lxc260 succeed (`pg_backup_last_success_timestamp`,
  `mariadb_backup_last_success_timestamp`).

## Failure modes

- `snapshot feature is not available`: `pct snapshot` refused the containers here; the script
  takes a `vzdump` archive instead.
- A container's service does not start after the reboot: read `journalctl -b -p 3` in it; for
  Apache on lxc210 the 8.2 module is still enabled until step 6 runs.
- `Pipx Internal Error: cannot find package ... metadata` for `ansible` during `pipx reinstall-all`:
  Debian 13's pipx cannot read the metadata the old venv carries, removes the venv and stops.
  Install it again with `pipx install --include-deps ansible==<version>`; the collections in
  `~/.ansible/collections` are not touched.

## Rollback

`lxc-trixie-upgrade.sh <ctid> rollback` prints the `pct restore` command for the archive taken
in step 4, in `/mnt/vzdump/pre-trixie/`. Data on bind mounts (Docker data roots, the PostgreSQL
data directory, the SMB shares) is not in that archive and is not touched by the upgrade; the
PostgreSQL 15 cluster stays in `/var/lib/postgresql/15/main` until it is dropped.

## Background

The upgrade runs inside the container as a transient systemd unit started through `pct exec` on
the hypervisor. Upgrading the `tailscale` package restarts `tailscaled`, which would cut an SSH
session into the container halfway through `dpkg`; `pct exec` does not use the container's
network, and the unit keeps running if the caller goes away.

`pg_upgradecluster -m dump` restores into a cluster created by `initdb` under the new glibc, so
every index is rebuilt with the new collation rules. A binary upgrade would carry the old indexes
over and leave the collation version mismatch that Debian 13's glibc 2.41 reports.

`autoremove` is skipped where a package from Debian 12 is still in use: removing `postgresql-15`
would take the binaries from under a running cluster, and removing the PHP 8.2 packages would
discard the configuration step 6 reads.
