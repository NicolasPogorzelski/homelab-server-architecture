# Off-Site Backup Target

## Status

Decided 2026-09-01.

## Context

Every copy of this platform's data is in one flat. The database dumps are on vm102's SMB share, the guest
backups on the auxiliary disk, the user files on the MergerFS pool under SnapRAID parity. Tier 1
item 3 of the [remediation plan](../platform/remediation-plan.md) has carried "no off-site copy"
since the plan was written.

Set against the threats that actually apply, three of five are already answered:

| Threat | Covered by | Holds? |
|---|---|---|
| A disk fails | SnapRAID parity, guest backup on a second disk | Yes |
| A guest is destroyed or misconfigured | Weekly `vzdump`, restored once on 2026-08-21 | Yes |
| A file is deleted and noticed late | A week of guest backups, seven days of dumps | Partly |
| Ransomware | nothing | No |
| Site loss - fire, theft, water, seizure | nothing | No |

Parity makes the ransomware case worse rather than better, because the next `snapraid sync` writes
the damage into the parity.

The credential form of that threat is the sharper one. Any account able to write these backups can
delete them, and lxc250 has held hypervisor root since 2026-08-21.

## How much data

Measured on vm102, 2026-09-01:

| Dataset | Size |
|---|---|
| Nextcloud user files | 35 GB |
| Paperless documents | 5.6 GB |
| PostgreSQL dumps | 322 MB |
| MariaDB dumps | 18 MB |
| Vaultwarden archive, until 2026-11-30 | 728 KB |
| **Total** | **about 41 GB** |

Small enough that the choice of target is not driven by volume. `restic` deduplicates and
compresses, so the first snapshot is smaller than this and later ones cost only what changed.

## Requirements

1. **A second site.** The definition of the control.
2. **Deletion resistance.** The copy has to survive a compromised credential on this side. The
   backup account must be able to write and not to delete.
3. **Client-side encryption.** The data includes identity documents, so it must be unreadable to
   whoever operates the target.
4. **Usable in practice.** A control that is not exercised is worth less than a weaker one that
   is. This platform's history holds a run of scheduled manual tasks that stopped happening.
5. **Cost proportional to the data.** Single-digit euros per month at 41 GB.

## Options

| Option | Deletion resistance | Day-to-day usability | Assessment |
|---|---|---|---|
| Small VPS with an `restic` REST server in append-only mode | Good, by configuration rather than by the storage service | High - a familiar kind of machine to run, and it can carry more than backups | **Chosen** |
| S3-compatible object storage with Object Lock | Strongest, enforced by the provider | Narrow - it does one job | Rejected: better guarantee, less usable, and it cannot carry the other two purposes |
| Managed storage box over SSH | Partial - snapshots, or append-only keys on rsync.net | Medium | Middle option that wins on nothing |
| Rotated encrypted disk kept elsewhere | Total, by being unplugged | Depends on visits, which are irregular | Already exists in this form and cannot be scheduled - see below |

## Decision

A small VPS at a European provider, running `rest-server` in append-only mode, written to by
`restic` from the homelab. Hetzner Cloud is the working assumption: smallest instance plus a volume,
since 41 GB does not fit an instance's own disk with room for history.

This reverses the recommendation an earlier draft of this document made for object storage, and the
reversal rests on usability rather than on a technical error. Object Lock is the stronger guarantee:
the storage service refuses deletion, so nobody, including the account owner, can remove a locked
object. A VPS cannot match that, because whoever holds root on the VPS can remove anything.

It wins on requirement 4 and on scope. A server is inspected, extended and repaired here as a
matter of routine; a bucket would be an API touched twice a year. The VPS also carries the three
purposes the remediation plan originally wanted from it, of which two are taken up now.

### Compensating controls, since Object Lock is not available

The append-only property has to be built rather than bought. Without these, this decision is
materially worse than the alternative it replaces.

| Control | What it provides |
|---|---|
| `rest-server --append-only` | The backup credential can add snapshots and cannot delete or overwrite them. This is the property Object Lock provides, enforced by the server process instead of by the storage service |
| A dedicated unprivileged account for the repository, with no shell | A compromised homelab reaches the repository and nothing else on the VPS |
| `restic forget --prune` runs on the VPS, on its own schedule | Writing and reclaiming are separate privileges held by different accounts |
| Provider volume snapshots | A second layer that root on the VPS does not remove in passing |

### Residual risk

Whoever holds root on the VPS can delete the repository. Provider snapshots shrink that window and
do not close it. Against the position on 2026-09-01 - every copy in one flat, all of them reachable
from a control node that holds hypervisor root - this is a large improvement and not an absolute
one.

## Scope: what the VPS carries

**Now.** The backup repository, and a second copy of the credential escrow described in Tier 1
item 1. Both are small, both are things whose loss is unrecoverable, and neither needs the VPS to be
running to be useful.

**Not yet: Terraform state.** Putting the state for the VPS onto the VPS is circular - destroying or
rebuilding it destroys the record of how it was built. State stays local on lxc250 for the early
Terraform work. If it moves to a remote backend later, the right target is object storage even
though the backups are not going there, because a state backend wants exactly the properties a
bucket has and none of the ones a server has.

## What already exists

Two copies are held away from the server and were recorded nowhere until now.

- **A rescue of the auxiliary disk's contents**, taken to an administrator workstation on
  2026-06-25, still there on encrypted storage. A point-in-time copy, roughly ten weeks old.
- **A disk at a second residential site**, holding a mirror taken in May 2026. Genuinely off site
  and genuinely air-gapped. It is refreshed only during a visit in person, which is irregular and
  not a schedule, so its age in between is unknown and cannot be planned around. Its scope is the
  same as `vzdump`'s: the guest root filesystems, and so the databases that live inside them. The
  archive pool is not in it, which means none of the C1 documents this decision is about - the
  Nextcloud files, the Paperless documents, the dump sets - has an off-site copy today.

Neither is a running backup and neither has been restored from. They are the reason "no off-site
copy of anything" was inaccurate. The second one is also the clearest argument for this decision: it
is the strongest control on the list and the one that cannot be given a cadence.

## Relationship to the Terraform track

Provisioning this VPS declaratively - instance, volume, firewall, SSH keys, `cloud-init` - is a
substantially better first Terraform exercise than a bucket, which has four attributes and no
lifecycle.

The VPS is still created by hand first, and Terraform adopts it afterwards with `terraform import`.
The track was deferred on 2026-09-02, the day after this decision, and has no start date. Tying an
open Tier 1 item to it would repeat, one layer up, the mistake that left the PostgreSQL dumps on a
cron schedule the host slept through: the plan read correctly and the mechanism never ran.

## Open points

- Provider and instance size are a working assumption, not a purchase. Confirm at signup.
- The `restic` repository password must reach the escrow before the first snapshot. A repository
  whose password lives only on the machine being backed up is not a backup.
- The VPS itself needs patching, monitoring and a backup of its own configuration. It is a tenth
  machine, and the binding constraint here is attention rather than money. That cost is accepted
  and should be recorded once the machine exists.

## Consequences

- Ransomware and site loss stop being unanswered, subject to the append-only configuration actually
  being in place. It is the part most easily skipped during setup and the part the whole decision
  rests on.
- Monthly cost moves from zero to single-digit euros.
- An off-site copy that has never been restored from is worth as much as an untested backup, so the
  restore drill and its recorded date are part of this decision.

## Verification

- `rest-server` reachable only over Tailscale, running with `--append-only`, confirmed by attempting
  a `restic forget` from the homelab and having it refused.
- Repository initialised, first snapshot written, `restic check --read-data` passing.
- A test restore of one file from each dataset in the table above, with the date recorded.
- A staleness alert on the last successful snapshot, shaped like `PostgreSQLBackupStale`, with its
  known limitation understood: it cannot see an outage while the host that runs Prometheus is off.

## Related Documents

- [Data Classification](../platform/data-classification.md)
- [Remediation Plan](../platform/remediation-plan.md)
- [Vaultwarden Decommissioning](./vaultwarden-decommission.md)
- [PostgreSQL restore runbook](../../runbooks/database/pg-restore.md)
