# Off-Site Backups Go to an Append-Only restic Server on a Small VPS

## Status
Accepted 2026-09-01. Not implemented: the `offsite_backup` role, `ansible/playbooks/offsite-backup.yml`,
the `offsite` alert group and two runbooks exist; the VPS is not provisioned, the role is not
deployed, and no off-site copy exists. First item of the
[remediation plan](../platform/remediation-plan.md#off-site-backup). Supersedes / superseded by: -.

## Context
Every copy of the platform's data is on one site: the database dumps on vm102's SMB share, the guest
backups on the aux-disk, the user files on the MergerFS pool under SnapRAID parity.

| Threat | Covered by | Holds? |
|---|---|---|
| A disk fails | SnapRAID parity; guest backup on a second disk | Yes |
| A guest is destroyed or misconfigured | Weekly `vzdump`, restore exercised 2026-08-21 | Yes |
| A file is deleted and noticed late | A week of guest backups and of dumps | Partly |
| Ransomware | nothing | No |
| Site loss: fire, theft, water, seizure | nothing | No |

Parity makes ransomware worse: the next `snapraid sync` writes the damage into the parity. Any
account that can write these backups can delete them, and lxc250 holds hypervisor root.

Measured on vm102, 2026-09-01: the user files and both dump sets together are under 100 GB.
`restic` deduplicates and compresses, so volume does not drive the choice of target.

Two copies outside the server exist, neither running nor restored from (recorded 2026-09-01): a
rescue of the aux-disk's contents on an administrator workstation, taken 2026-06-25, and a disk at a
second site holding a mirror from May 2026. The second is off site and air-gapped but refreshed
only at irregular intervals, and its scope is the guest root filesystems; the archive
pool, and so the Nextcloud files, Paperless documents and dump sets, has no off-site copy.

Requirements:

1. A second site.
2. Deletion resistance: the backup credential can write and cannot delete.
3. Client-side encryption: the data includes identity documents.
4. Exercised in routine operation: a target touched twice a year falls out of use.
5. Single-digit euros per month for under 100 GB.

## Options
- **Rotated encrypted disk kept elsewhere.** Not as the main control: the strongest protection
  (unplugged), but it depends on visits and cannot be scheduled. It exists in this form already.
- **Managed storage box over SSH.** Partial deletion resistance (snapshots, or append-only
  keys at some providers) and wins on no requirement.
- **S3-compatible object storage with Object Lock.** The strongest deletion guarantee,
  enforced by the provider, but a bucket is an API touched rarely (requirement 4) and carries nothing
  else the platform needs.
- **A small VPS running `rest-server` in append-only mode.** Chosen.

## Decision
A small VPS at a European provider runs `rest-server --append-only`; `restic` on the homelab writes
to it over Tailscale. Hetzner Cloud is the working assumption: the smallest instance plus a volume,
since the C1 set with history does not fit the instance disk. Each source node (vm102 for the user
files and dumps, lxc250 for the credentials every recovery depends on) gets its own repository and
append-only account. The VPS also holds a second copy of the credential escrow
([escrow drill](../platform/remediation-plan.md#escrow-restore-drill)).

Object Lock is not available on a VPS, so the append-only property is built:

| Control | What it provides |
|---|---|
| `rest-server --append-only` | The backup credential adds snapshots and cannot delete or overwrite them |
| A dedicated unprivileged account without a shell owns the repositories | A compromised homelab reaches the repositories and nothing else on the VPS |
| `restic forget --prune` runs on the VPS on its own schedule | Writing and reclaiming are held by different accounts |
| Provider volume snapshots | A layer that root on the VPS does not remove in passing |

Terraform state does not go to the VPS: state for a machine stored on that machine is lost with it.
It stays local on lxc250; a later remote backend would be object storage. The VPS is created by hand
([`offsite-vps-provision.md`](../../runbooks/platform/offsite-vps-provision.md)) and adopted by
Terraform later, so the backup does not wait for the Terraform track.

## Consequences
- Ransomware and site loss are answered once the append-only configuration is in place; it is the
  part the decision rests on and the easiest to skip during setup.
- Residual risk: root on the VPS can delete the repositories. Provider snapshots narrow that window
  and do not close it.
- The `restic` repository password must reach the escrow before the first snapshot.
- One more machine to patch, monitor and back up; monthly cost moves from zero to single-digit
  euros.
- `OffsiteBackupFailed`, `OffsiteBackupStale` and `OffsiteBackupUnverified` cannot see a missed run
  while the host that runs Prometheus is off.

## Verification
Done when, with dates recorded in [`offsite-backup.md`](../../runbooks/backup/offsite-backup.md):

- `rest-server` is reachable only over Tailscale, runs with `--append-only`, and a `restic forget`
  from the homelab is refused;
- the repositories are initialised, a first snapshot is written and `restic check --read-data`
  passes;
- one file from each dataset above is restored from the VPS.

## Related Documents
- [Data classification](../platform/data-classification.md)
- [Remediation plan](../platform/remediation-plan.md)
- [Identity before Terraform](identity-before-terraform.md)
