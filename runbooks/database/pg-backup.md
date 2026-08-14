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
| Schedule | `pg-backup.timer`, `OnCalendar=*-*-* 03:00:00`, `Persistent=true` |
| Compression | gzip |
| Target | `/mnt/backups/` (SMB on MergerFS) |
| Write | to `*.sql.gz.partial`, renamed only after verification passes |
| Verification | non-empty · `gzip -t` · exactly one `dump complete` marker |
| Retention | 7 days, both `*.sql.gz` and `*.sql.gz.partial` — runs only after verification |
| Auth | peer (no password, local socket) |

### Install steps (CT260)

Deployment is owned by the [`postgresql_backup`](../../ansible/roles/postgresql_backup/) role —
script, service unit, timer and textfile directory. There are no manual install steps, and the
role also removes the legacy cron entry it used to install.

```bash
# from the control node, dry run first
ansible-playbook playbooks/pg-backup.yml --check --diff
ansible-playbook playbooks/pg-backup.yml
```

**Not cron.** The Proxmox host powers down before 03:00 every night, so a cron slot is simply
missed and lost — that is why backups had silently not run for 26 days when this was found on
2026-07-10. A timer with `Persistent=true` runs the overdue dump at the next boot instead, and a
failed timer unit raises `SystemdUnitFailed` where a cron failure raised nothing.

---

## Verification
```bash
# Check the schedule (a timer, not cron -- see Notes)
systemctl list-timers pg-backup.timer
journalctl -u pg-backup.service -n 30

# Manual test run
systemctl start pg-backup.service

# Inspect backup directory. A *.sql.gz.partial file left behind means the run
# failed verification -- the dump is deliberately not published under the real name.
ls -la /mnt/backups/

# Validate dump content (expect SQL header + CREATE ROLE statements)
zcat /mnt/backups/pg_dumpall_<timestamp>.sql.gz | head -20

# Re-run the script's own acceptance test against any dump on the share
gzip -t /mnt/backups/pg_dumpall_<timestamp>.sql.gz && echo "stream intact"
gzip -cd /mnt/backups/pg_dumpall_<timestamp>.sql.gz \
  | grep -c 'PostgreSQL database cluster dump complete'   # must print exactly 1
```

A dump that passes `gzip -t` but prints `0` on the last command is **truncated**: `pg_dumpall`
stopped early and what it managed to emit was compressed correctly. It will restore without a
single error and leave the tables empty. That is why the marker check exists and why
`gzip -t` alone is not enough.

---

## Failure Modes

| Symptom | Likely Cause | Action |
|---|---|---|
| `is not a CIFS mount` | SMB mount missing or down | Check `findmnt /mnt/backups`, verify VM102 Samba, then `pct reboot 260` — a container whose bind was set up while the mount was down does not heal by itself (KE-15) |
| `dump is empty` | PostgreSQL not running | Check `pg_isready`, inspect PG logs |
| `fails the gzip integrity check` | Write interrupted, or the share filled up | `df -h /mnt/backups`; check the MergerFS pool on vm102 (`ArchivePoolLowSpace`) |
| `0 completion markers, expected 1` | `pg_dumpall` died mid-dump | Inspect `journalctl -u pg-backup.service`; check PG logs for an OOM kill or a connection drop |
| `.partial` file on the share, no new dump | A run failed verification | The old dumps are intact — verification runs *before* retention deletion, so nothing was removed. Diagnose from the messages above |
| Permission denied | Script ownership wrong | Verify `root:postgres` and mode 750 |
| Timer not firing | Timer disabled or unit failed | `systemctl list-timers pg-backup.timer`, `systemctl status pg-backup.timer` |
| Stale backups (no recent files) | Failed run, or the host was simply powered off | `journalctl -u pg-backup.service`. Note gaps are normal: the host powers down nightly, and `Persistent=true` runs one catch-up at the next boot — several missed nights coalesce into a **single** dump |

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
