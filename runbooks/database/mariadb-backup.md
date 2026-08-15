# Runbook: Nextcloud MariaDB automated backup (mariadb-dump)

## Problem

Nextcloud on lxc210 runs its own MariaDB instance, inside the container. The nightly `pg_dumpall`
covers the PostgreSQL cluster on lxc260 and nothing else, so this database was **never backed up** —
no role, no script, no unit, no crontab entry. Verified live on 2026-08-15: empty root crontab,
`/etc/cron.d/` holding only `e2scrub_all`, `nextcloud` and `php`, eleven timers of which none is a
dump, and not a single non-PostgreSQL dump anywhere under `/mnt/smb`.

The consequence is worse than a missing backup usually is. Nextcloud's user files live on the
archive pool on vm102; its database lives on the boot SSD with the unresolved
[KE-14](../../docs/platform/known-errors.md#ke-14) I/O faults. Losing that SSD leaves **every user
file intact and unusable** — without the database, Nextcloud's storage layout is a tree of opaque
blobs with no owner, no filename and no share. The two halves of one dataset sit on different disks
with different protection, and the weaker half is the one that makes the other meaningful.

## Solution (CT210)

A `mariadb-dump --all-databases` written to the SMB backup share nightly by a systemd timer,
verified at write time before any older dump is deleted, and exposed to Prometheus through a
textfile metric so a silent stop raises `MariaDBBackupStale`.

Deliberately the same shape as [`pg-backup.md`](pg-backup.md), because the failure modes are the
same and a second pattern would be a second thing to remember.

## Preconditions

The role **asserts** these rather than creating them, and refuses to deploy if they are missing.
Deploying a timer against an absent mount installs a unit that fails every night, which reads as a
broken backup rather than as an unfinished installation.

1. **A backup share exists on vm102** and is exported over SMB.
2. **The Proxmox host mounts it** under `/mnt/smb/db-backups`, with `x-systemd.automount` in the
   fstab entry. This is not optional: the host mounts from vm102, **a guest it starts itself**, so
   at boot the SMB server does not exist yet. A plain entry is tried once, fails, and is never
   retried — that is [KE-15](../../docs/platform/known-errors.md#ke-15), and it cost a month of
   silent failures the last time it was overlooked.
3. **The container binds it** as `mp1: /mnt/smb/db-backups,mp=/mnt/backups` in
   `/etc/pve/lxc/210.conf`.
4. `node_exporter_textfile_dir` is set in `host_vars/lxc210.yml` — already included in this change.

### Provisioning the share (one time, before the first run)

Steps 1–3 above touch vm102 and the Proxmox host. The host is not an Ansible node, so these are
manual and belong here rather than in a role.

```bash
# 1. On vm102: create the directory and export it.
#    Mirror the [Postgres-backups] stanza in snippets/storage/ — same dedicated
#    service user pattern, so a compromised container cannot read another's backups.
sudo mkdir -p /mnt/mergerfs/DB-Backups
sudo chown <backup-user>:<backup-group> /mnt/mergerfs/DB-Backups
sudo chmod 0770 /mnt/mergerfs/DB-Backups
# add the [DB-Backups] share to /etc/samba/smb.conf, then:
sudo testparm -s          # must parse cleanly before reloading
sudo systemctl reload smbd

# 2. On the Proxmox host: fstab entry, modelled on the existing postgres-backups line.
#    Note it uses vm102's TAILSCALE address, not the LAN address — the same choice
#    already made for the PostgreSQL share.
sudo mkdir -p /mnt/smb/db-backups
sudo vi /etc/fstab        # copy the existing postgres-backups line and adjust share,
                          # mountpoint and uid/gid — it already carries the correct
                          # option set, including x-systemd.automount
sudo systemctl daemon-reload

# daemon-reload REGENERATES the .mount/.automount units from fstab but does not START
# a newly generated automount unit. Skipping this line leaves an empty directory that
# every `ls` reports as fine -- which is the KE-15 shape exactly. Found by running this
# procedure: the first attempt "succeeded" and nothing was mounted.
sudo systemctl start "$(systemd-escape -p --suffix=automount /mnt/smb/db-backups)"

# Verify with findmnt, never with ls. `ls` on an unmounted mountpoint succeeds.
findmnt -no FSTYPE,SOURCE /mnt/smb/db-backups   # must print: cifs //<vm102>/DB-Backups

# 3. On the Proxmox host: bind it into the container, then restart it.
sudo pct set 210 -mp1 /mnt/smb/db-backups,mp=/mnt/backups
sudo pct reboot 210
```

**`pct reboot` is required, not optional.** A container whose bind was configured while the host
mount was down does not heal by itself — the container keeps the empty directory it saw at start.

### Install steps (CT210)

```bash
# from the control node, dry run first
cd ~/git/homelab-server-architecture/ansible
ansible-playbook playbooks/mariadb-backup.yml --check --diff
ansible-playbook playbooks/mariadb-backup.yml
```

## Verification

```bash
# The precondition the role asserts — must print 'cifs'
pct exec 210 -- findmnt -no FSTYPE /mnt/backups

# Schedule: a timer, not cron. The host sleeps at night, so Persistent=true is load-bearing.
pct exec 210 -- systemctl list-timers mariadb-backup.timer --all

# Manual test run
pct exec 210 -- systemctl start mariadb-backup.service
pct exec 210 -- systemctl show mariadb-backup.service -p Result -p ExecMainStatus
pct exec 210 -- journalctl -u mariadb-backup.service -n 5 --no-pager

# Inspect the share. A *.sql.gz.partial left behind means the run failed verification —
# the dump is deliberately not published under the real name.
ls -lh /mnt/smb/db-backups/

# Re-run the script's own acceptance test against any dump on the share
gzip -t /mnt/smb/db-backups/mariadb_all_*.sql.gz && echo "gzip OK"
zcat /mnt/smb/db-backups/mariadb_all_*.sql.gz | grep -c '^-- Dump completed on '   # expect 1

# The metric that arms the alert
pct exec 210 -- cat /var/lib/node_exporter/textfile_collector/mariadb_backup.prom
# and that Prometheus actually sees it:
#   mariadb_backup_last_success_timestamp
```

### Verification record

| Date | Result |
|---|---|
| 2026-08-15 | **Provisioned and applied end to end. Pass.** Share `DB-Backups` created on vm102 (dedicated `mariadb-bk` account, `force user = storage`, mode 0770), host fstab entry cloned from the postgres-backups line with `uid=100000,gid=100000` — root inside an unprivileged container maps to host uid 100000 — mount confirmed `cifs` by `findmnt`, host write test produced a file owned by `100000`. Bind `mp1` added, `pct reboot 210`, mount confirmed `cifs` **inside** the container, Apache and MariaDB back `active`, no failed units. Playbook `changed=4`, second run `changed=0`. Manual run: `Result=success`, `ExecMainStatus=0`, journal line `OK: /mnt/backups/mariadb_all_20260815_124422.sql.gz (2.2M), gzip and completion marker verified`. Dump independently re-checked on the share: `gzip -t` clean, **exactly one** completion marker, 209 `CREATE TABLE` statements. Metric scraped by Prometheus under `job="node-lxc210-nextcloud"`. `MariaDBBackupStale` promoted through the role's stage → validate → promote path (17 rules loaded, up from 16) and its expression returns an empty vector, i.e. correctly inactive against a fresh dump. Timer armed for 2026-08-16 03:34:14 UTC — 03:30 plus 4 min 14 s, which is `RandomizedDelaySec=300` doing its job. **One defect found by executing this runbook:** the provisioning section above omitted `systemctl start <unit>.automount`, so the first attempt reported success with nothing mounted. Corrected in the same commit. |

## Failure Modes

| Symptom | Cause | Action |
|---|---|---|
| Role refuses to run: "not a CIFS mount" | The share, fstab entry or bind mount is missing | Work through the provisioning steps above. Do not create `/mnt/backups` by hand to satisfy the check — that is exactly the failure it exists to prevent. |
| `ERROR: … is not a CIFS mount` in the journal | The host mount dropped after deployment | Check the automount unit on the host; `pct reboot 210` after it is back. The script correctly refuses rather than filling the container rootfs on the boot SSD. |
| `ERROR: dump carries 0 completion markers` | `mariadb-dump` died mid-write | The `.partial` file is kept as evidence. Check free space on the pool (`ArchivePoolLowSpace`) and the MariaDB error log. No previous dump was deleted — retention runs only after verification passes. |
| `MariaDBBackupStale` fires | No verified dump for >25 h of **uptime** | Run the manual test above. Note the rule cannot see an outage in which the host was off, because Prometheus runs on that host. |
| No alert, but no dumps either | The metric was never written, so the series is absent and the rule evaluates to nothing | Confirm `node_exporter_textfile_dir` is set for lxc210 and that the collector flag is live in the unit. |
| Dump succeeds, restore fails on charset | Connection charset mismatch | The script pins `--default-character-set=utf8mb4`; if a future change removes it, filenames transcode silently on the way out. |

## Restore (high-level)

Not yet exercised. The first execution of this path, with the date recorded, is the outstanding item
— the same discipline the PostgreSQL restore now follows, and for the same reason: an untested
backup is a belief, not a control.

```bash
# Stop Nextcloud's web front end first, so nothing writes during the restore.
pct exec 210 -- systemctl stop apache2

# Restore. --all-databases dumps include the mysql database, so users and grants return with it.
pct exec 210 -- bash -c 'zcat /mnt/backups/mariadb_all_<timestamp>.sql.gz | mariadb'

pct exec 210 -- systemctl start apache2
```

Restore into a throwaway instance rather than over the live one wherever the goal is *validation*
rather than recovery — see the non-destructive procedure in [`pg-restore.md`](pg-restore.md), which
is directly transferable.

## Rollback

Everything this runbook installs is additive, so backing it out cannot lose data.

**The role:**

```bash
pct exec 210 -- systemctl disable --now mariadb-backup.timer
pct exec 210 -- rm /etc/systemd/system/mariadb-backup.service /etc/systemd/system/mariadb-backup.timer
pct exec 210 -- systemctl daemon-reload
```

**The provisioning**, in reverse order — bind mount, then host mount, then share:

```bash
sudo pct set 210 -delete mp1
sudo pct reboot 210
sudo umount /mnt/smb/db-backups   # then remove the fstab line and daemon-reload
# on vm102: remove the [DB-Backups] stanza, reload smbd
```

Leave the dumps in place if the share survives. They are the only reason any of this exists, and
nothing needs the units in order to read them back.

**Abort criteria:** stop before `pct set` if `ls /mnt/smb/db-backups` on the host errors — binding a
mount that is not up produces a container pointing at an empty directory that looks exactly like a
working one, and the dump would then land in the container rootfs on the boot SSD. That is the KE-7
class, and it is why the role asserts the mount rather than creating the path.

**Nothing here is irreversible**, which is the unusual part and worth saying out loud: this runbook
adds a backup where none existed. The risk of running it is low; the risk of not running it is the
whole reason it was written.

---
## Notes

- **Why a timer and not cron:** the Proxmox host is powered down overnight and woken by RTC. A cron
  job at 03:30 is simply missed and lost. `Persistent=true` fires the overdue run at the next boot.
  This is not theoretical — it is how the PostgreSQL dumps stopped for two months.
- **Why `RandomizedDelaySec=300`:** after an overnight power-down both database timers are overdue
  and fire within seconds of each other, streaming to the same CIFS server. The delay separates them
  without ordering one unit after the other, which would make each backup depend on a database it
  has nothing to do with.
- **Why root:** `mariadb-dump` authenticates through the `unix_socket` plugin, so no password is
  stored anywhere. A dedicated backup account would need a credential on the node, in the vault, and
  in a rotation schedule.
- **Retention is 7 days, not 7 dumps.** `find -mtime +7` truncates to whole days and `+7` requires
  strictly greater, so it is effectively 8. On a host that sleeps, a quiet week leaves fewer files
  than days.
