# Runbook: off-site backup with restic

## Problem

Every copy of this platform's data is in one flat. The database dumps sit on vm102's archive pool,
the guest backups on the auxiliary disk, the user files on the same pool under SnapRAID parity.
Parity answers the loss of a disk and nothing else: deletion, corruption and ransomware are
legitimate writes as far as the array is concerned, and the next `snapraid sync` copies the damage
into the parity.

The credential form is sharper than the fire-and-theft form. Any account able to write these
backups can delete them, and lxc250 has held hypervisor root since 2026-08-21.

## Solution

`restic` from the nodes that hold C1 data to a `rest-server` running in append-only mode on a
small VPS at a second site. The backup credential can create and read snapshots and cannot remove
anything, so a credential stolen from this side cannot destroy the copy it was stolen to reach.
Retention is applied on the server, by a different account.

The C1 scope is defined in [`data-classification.md`](../../docs/platform/data-classification.md)
and is about 41 GB. Two source nodes:

| Node | What it sends | Why it is separate |
|---|---|---|
| vm102 | Nextcloud files, Paperless documents, both dump sets, the retained Vaultwarden archive | The archive pool is local here; the Proxmox host sees it over CIFS |
| lxc250 | The vault password, the real inventory and the automation SSH key | Without these no other restore can be performed, and they exist in one copy on a failing SSD |

Each node uses a repository and an append-only account of its own. One repository shared by
both would mean a compromise of vm102 could read lxc250's credentials, which is the one dataset
whose disclosure makes everything else reachable.

## Preconditions

The role asserts these and refuses to deploy if they are missing.

1. **The VPS exists and runs `rest-server --append-only`.** Provisioning is a separate procedure:
   [`platform/offsite-vps-provision.md`](../platform/offsite-vps-provision.md).
2. **Both repositories are initialised** - `restic init` is the one operation an append-only
   account cannot perform, so it is done once from the server side during provisioning.
3. **`vault_offsite_backup_repository` and `vault_offsite_backup_password` exist** in the vaulted
   `group_vars` of the inventory on lxc250. They are references in this repository and values
   nowhere in it.
4. **`offsite_backup_paths` is set in `host_vars`** for each source node. The role carries no
   fleet-wide default on purpose: a wrong path is silently skipped by `restic backup`, which then
   exits 0 having copied less.
5. **The repository password is escrowed on paper, off site.** A `restic` repository whose password
   is lost is indistinguishable from one that was never taken. It goes in the same envelope as the
   Ansible vault password, and the annual escrow check covers both.

## Commands

Deploy or update:

```bash
cd ~/git/homelab-server-architecture/ansible
ansible-playbook playbooks/offsite-backup.yml --check --diff
ansible-playbook playbooks/offsite-backup.yml
```

First run by hand, watching it, rather than waiting for 04:15:

```bash
systemctl start offsite-backup.service
journalctl -u offsite-backup.service -f
```

List what the repository holds:

```bash
export RESTIC_REPOSITORY="$(grep '^RESTIC_REPOSITORY=' /etc/offsite-backup.env | cut -d= -f2-)"
export RESTIC_PASSWORD_FILE=/etc/offsite-backup.pass
restic snapshots
```

Restore a single path into a scratch directory - never over the original:

```bash
restic restore latest --target /var/tmp/restore-check --include /mnt/mergerfs/Paperless
```

## Verification

1. The unit finished: `systemctl show offsite-backup.service -p Result` reads `success`.
   **Read the journal as well.** `systemctl reset-failed` clears that field, so a reset failure and
   a genuine success are indistinguishable in it - measured on this platform on 2026-09-08.
2. The metric was written and is readable:
   `awk '/^offsite_backup_/' /var/lib/node_exporter/textfile_collector/offsite-backup.prom`
   shows `offsite_backup_success 1` and a fresh timestamp. Mode must be `0644`; node_exporter
   skips a file it cannot read and logs nothing.
3. Prometheus has it: `offsite_backup_success` returns a sample per source node.
4. A restore was actually performed, not merely offered. Restore one file into
   `/var/tmp/restore-check`, compare it against the original with `cmp`, and record the date here
   the way [`pg-restore.md`](../database/pg-restore.md) does.

| Date | Scope restored | Result |
|---|---|---|
| *(not yet run)* | | |

## Failure modes

- **`repository is unreachable or the password is wrong`.** The script checks this before reading
  any data, so the run costs a second rather than an hour. Check the VPS is up, then that the
  password file matches the repository - a rotated password on the server invalidates every client.
- **`restic forget` or `restic prune` fails.** Correct and deliberate. The client credential is
  append-only; retention runs on the server under a different account. Do not "fix" this by
  granting the client delete rights - that removes the control the target was chosen for.
- **The run succeeds and the snapshot is smaller than expected.** A source path that does not exist
  is skipped by `restic backup` with exit 0. Both the role and the script check every path for
  this reason; if a path was renamed, the check fails loudly instead.
- **`OffsiteBackupStale` is silent while no backup has run.** Known and structural: Prometheus runs
  on the same site, so a period with the host off produces no scrape, and `Persistent=true`
  refreshes the timestamp before Prometheus returns. The rule means "not more than 50 hours of
  uptime without an off-site copy". The answer to that class is the external heartbeat in the
  [remediation plan](../../docs/platform/remediation-plan.md), not a longer window.
- **The first run is very slow.** 41 GB over a domestic uplink. `TimeoutStartSec=21600` allows six
  hours; a run cut short leaves a partial snapshot the next run has to redo from the start.

## Rollback

Stop and disable the timer, and leave the repository alone:

```bash
systemctl disable --now offsite-backup.timer
```

The repository is deliberately outside the rollback. The client cannot delete from it, and
that is the property being bought; removing snapshots is a server-side operation done knowingly.
Removing the role from a node stops new copies and destroys none.
