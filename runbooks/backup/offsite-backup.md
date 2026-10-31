# Runbook: off-site backup with restic

- **Use when:** deploying the `offsite_backup` role once the VPS exists, running an off-site backup
  by hand, restoring from the off-site copy, or an `OffsiteBackup*` alert fires.
- **Duration:** 15 minutes to deploy; the first run takes hours (`TimeoutStartSec=21600`).
- **Risk:** low for the source data, which is only read. A wrong `offsite_backup_paths` entry is
  skipped by `restic backup` with exit 0; the role and script check every path for this reason.
- **Last exercised:** never. The VPS is not provisioned and the role is not deployed, so no
  off-site copy exists yet ([remediation plan](../../docs/platform/remediation-plan.md#off-site-backup)).

Every copy of the platform's data is on one site. SnapRAID parity covers the loss of a disk, not
deletion, corruption or ransomware; any account able to write the local backups can delete them,
and lxc250 holds hypervisor root. The target, decided in
[offsite-backup-target.md](../../docs/decisions/offsite-backup-target.md): `restic` to a
`rest-server --append-only` on a small VPS. The client credential can create and read snapshots and
cannot remove any; retention runs on the server under a different account.

Scope is the C1 set in [data-classification.md](../../docs/platform/data-classification.md):

| Node | What it sends | Why separate |
|---|---|---|
| vm102 | Nextcloud files, Paperless documents, both dump sets | The archive pool is local there |
| lxc250 | Vault password, real inventory, automation SSH key | Needed before any other restore can run |

Each node has its own repository and append-only account, so a compromise of vm102 cannot read
lxc250's credentials. Schedule, verification weekday and subset are in the role defaults.

## Preconditions

The role asserts these and refuses to deploy without them.

- The VPS runs `rest-server --append-only`: [offsite-vps-provision.md](../platform/offsite-vps-provision.md).
- Both repositories are initialised from the server side (`restic init` is the one operation an
  append-only account cannot perform).
- `vault_offsite_backup_repository` and `vault_offsite_backup_password` exist in the vaulted
  `group_vars` of the inventory on lxc250.
- `offsite_backup_paths` is set in `host_vars` for each source node; the role has no default.
- The repository passwords are escrowed on paper off site, with the Ansible vault password.

## Steps

1. Deploy, dry run first (from the repository's `ansible/` directory on lxc250).
   ```bash
   ansible-playbook playbooks/offsite-backup.yml --check --diff
   ansible-playbook playbooks/offsite-backup.yml
   ```
   Check: no failed asserts; a second run reports `changed=0`. Then move the playbook from
   `[excluded]` to `[playbooks]` in `ansible/drift-sweep.conf`.

2. Run the first backup by hand on each source node.
   ```bash
   systemctl start offsite-backup.service
   journalctl -u offsite-backup.service -f
   ```
   Check: the run ends without `ERROR`; `systemctl show offsite-backup.service -p Result` reads
   `success`. Read the journal as well: `systemctl reset-failed` also resets `Result`.

3. List the snapshots.
   ```bash
   export RESTIC_REPOSITORY="$(grep '^RESTIC_REPOSITORY=' /etc/offsite-backup.env | cut -d= -f2-)"
   export RESTIC_PASSWORD_FILE=/etc/offsite-backup.pass
   restic snapshots
   ```
   Check: a snapshot tagged with the node name and today's date.

4. Restore one path into a scratch directory, never over the original, and compare.
   ```bash
   restic restore latest --target /var/tmp/restore-check --include /mnt/mergerfs/Paperless
   cmp /var/tmp/restore-check/mnt/mergerfs/Paperless/<file> /mnt/mergerfs/Paperless/<file>
   ```
   Check: `cmp` prints nothing and exits 0. Record the date and scope in the `Last exercised` line.

## Verification

- `grep '^offsite_backup_' /var/lib/node_exporter/textfile_collector/offsite-backup.prom` shows
  `offsite_backup_success 1` and a current `offsite_backup_last_run_timestamp_seconds`. The file
  mode is `0644`; node_exporter skips a file it cannot read without logging.
- In Prometheus, `offsite_backup_success` returns one sample per source node.
- `OffsiteBackupFailed`, `OffsiteBackupStale` and `OffsiteBackupUnverified` are not firing.

## Failure modes

| Symptom | Cause | Action |
|---|---|---|
| `repository ... is unreachable or the password is wrong` | VPS down, or password file does not match the repository | Check the VPS, then `/etc/offsite-backup.pass`; a rotated server password invalidates every client |
| `restic forget` / `restic prune` fails | The client account is append-only | Run retention on the server; never grant the client delete rights |
| Snapshot smaller than expected | A source path was renamed | The path check fails loudly; fix `offsite_backup_paths` |
| `OffsiteBackupStale` silent while nothing ran | Prometheus runs on the same site and sees only uptime | Known limit; covered by the external heartbeat item in the remediation plan |
| First run cut off | Domestic uplink, `TimeoutStartSec` reached | Start it again by hand (step 2) and let it finish |

## Rollback

```bash
systemctl disable --now offsite-backup.timer
```

The repository is outside the rollback. The client cannot delete from it, which is the property
the target was chosen for; removing snapshots is a server-side operation. Removing the role from a
node stops new copies; existing snapshots stay in the repository.

## Background

Residual risk accepted in the decision: root on the VPS can still delete the repositories. A
restic repository whose password is lost is unreadable, which is why the password is escrowed and
covered by the [escrow restore drill](../platform/escrow-restore-drill.md).
