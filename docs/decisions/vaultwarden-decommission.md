# Decommissioning Vaultwarden

## Status

Decided and applied 2026-09-01. Phase 2 is dated 2026-11-30.

## Context

LXC240 ran Vaultwarden, a self-hosted implementation of the Bitwarden protocol, from January 2026.
It held this platform's credentials, and it existed partly so there would be a secrets tier to
point at.

It stopped being used in February. Measured on 2026-09-01, before deciding:

| Evidence | Value |
|---|---|
| `db.sqlite3` last modified | 2026-02-16 |
| Total data | 677 KB |
| Contents | 29 tables, one user, eleven vault items, four devices |
| Container | `vaultwarden/server:latest`, 1.36.0, up and healthy, restarted at every host wake |
| Guest backup | absent from the job's guest list until 2026-09-01 |
| Consistent export | never existed |
| Database location | CIFS mount from vm102 ([KE-5](../platform/known-errors.md#ke-5)) |
| Protection | SnapRAID parity, with the side files excluded since [KE-19](../platform/known-errors.md#ke-19) |

## Why it was not worth keeping

An unused service still costs patching, probing, certificate handling and backup. The patching had
already stopped: the image is `:latest` and has not been re-pulled since the
`docker-compose-update` hold began in June, so the running version is whatever was current then.

It also carried four open items - KE-5, KE-19, the last half of Tier 1 #3 in the
[remediation plan](../platform/remediation-plan.md), and its absence from the guest backup. That is
a lot of ledger for a service with one user who had stopped using it.

The security argument is shorter. A credential store is a target. One nobody logs into is a target
nobody is watching.

In control terms, A.8.10 asks that information no longer required be deleted and A.5.9 that the
asset inventory be current. Keeping it running would have failed both.

## Options considered

**Keep it as it was.** It preserved the appearance of a secrets tier while the substance - a
current, restorable, exported copy - did not exist. The obvious interview question about it had no
good answer.

**Build the export it never had.** A role and timer using SQLite's online backup API, since `cp` of
a live database is a bet on timing, plus a staleness alert shaped like `MariaDBBackupStale`. Real
work, correctly specified, in the service of something nobody used.

**Migrate to PostgreSQL on lxc260.** The end state KE-5 has named since it was written: the database
joins a cluster that is already dumped nightly, verified at write time and restore-tested monthly,
and the CIFS problem disappears. Roughly a day of work, with a data migration on a credential store
as the delicate part. Deferred, and kept as the reopening path below.

**Decommission.** Chosen.

## Decision

Withdrawn from service, in two stages, because retiring a service and destroying its data are
different acts.

**Phase 1, 2026-09-01.** Stop the whole guest, not just the Docker container inside it. An LXC kept
running for a service that no longer runs still carries an sshd, a Docker daemon and a Tailscale
node. Clear `onboot`. Take a cold archive while nothing is writing, of the whole file set rather
than the database alone. Remove the inventory entry, the scrape target and the HTTPS probe together
with the shutdown, or `NodeDown` fires permanently for a node that is off deliberately. The guest
stays in the `vzdump` list, which runs on the hypervisor against CTIDs and needs no inventory.

Container definition, root disk and the data on the share stay.

**Phase 2, on or after 2026-11-30.** Destroy the data on the share, remove the container, and clear
what it leaves in configuration: the `snapraid_maintenance` exclude rules for its side files, the
`storage_permissions` entry for its directory. Ninety days is long enough to cover a quarterly task
nobody remembered and short enough that the archive does not become permanent by neglect.

## What could not be exported, and why it did not matter here

Vaultwarden encrypts vault items client-side. The server stores ciphertext and cannot read it, so
the cold archive is a copy of encrypted blobs and the account metadata around them, not of the
secrets. A portable export has to come from a logged-in client, before the service stops.

The operator confirmed on 2026-09-01 that nothing in the vault was still needed - the credentials
that matter are in the external password manager and the paper escrow recorded in Tier 1 item 1 of
the remediation plan. No export was taken.

## What the shutdown measured

The three files looked wrong. `db.sqlite3` had an mtime of 2026-02-16 next to a 57712-byte
`db.sqlite3-wal` last written 2026-06-11, which reads like four months of committed transactions
stranded outside the database.

They were not. Asked directly, on a copy held on local storage, `PRAGMA wal_checkpoint(TRUNCATE)`
returned `(0, 0, 0)` - no frames in the log - and `PRAGMA integrity_check` returned `ok` both before
and after. The database file alone was complete.

The useful form of this is the one that survives the correction. A write-ahead log is not truncated
when its frames are checkpointed, so a stale allocation and a genuine backlog look identical from
the filesystem. Nothing short of opening the database can tell them apart.

One loose end. A clean SQLite close removes `-wal` and `-shm`, and both were still present after a
graceful `pct shutdown`. Something has been closing this database
untidily, which fits a container stopped by a nightly host power cycle. It no longer matters for
this service, and it may matter for the next one on CIFS.

## Consequences

- KE-5 is closed by removing its subject, not by solving SQLite-on-CIFS. A reader looking for that
  solution belongs in the PostgreSQL path above.
- Tier 1 #3 loses its last open half. What remains under that item is the off-site copy of the data
  that does exist.
- The credential escrow is now a single mechanism rather than one of two. The annual retrieval drill
  Tier 1 #1 prescribes is the only evidence that it works, which makes skipping it more expensive
  than it was yesterday.
- One fewer service to patch, probe, certify and back up.

## Reopening

If a self-hosted secrets store is wanted again, the route is the PostgreSQL migration, not this
design. The archive from phase 1 is the input, provided it is restored inside the retention window
and the master password still exists.

## Verification

Recorded 2026-09-01:

- `pct status 240` reports `stopped`, `pct config 240` reports `onboot: 0`.
- Cold archive holds both the raw file set and a checkpointed copy; `integrity_check` `ok`;
  identical `sha256` on the hypervisor and on an off-site workstation.
- Prometheus re-rendered from the role after a `--check --diff` run whose diff removed exactly two
  things. Afterwards: 18 active targets, none unhealthy, no firing alert, no reference to the
  service.
- `NodeDown` and `ServiceDown` for the stopped node appeared as `pending` on stale series and
  expired without firing.

## Related Documents

- [LXC240 Node](../nodes/lxc240.md)
- [Vaultwarden Service](../services/vaultwarden.md)
- [Remediation Plan](../platform/remediation-plan.md)
- [Data Classification](../platform/data-classification.md)
- [Known Errors](../platform/known-errors.md)
