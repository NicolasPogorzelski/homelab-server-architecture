# Vaultwarden Is Decommissioned

## Status
Implemented 2026-10-10. Withdrawn from service 2026-09-01, container destroyed 2026-09-29, share
data destroyed 2026-10-10. The cold archive is deleted on 2026-11-30. Supersedes / superseded by: -.

## Context
lxc240 ran Vaultwarden, a self-hosted Bitwarden-compatible password manager, from January 2026: an
unprivileged Debian 12 LXC with one Docker Compose service, `tag:tier1`, bound to `127.0.0.1:8080`
and published through `tailscale serve` on 443. Its SQLite database lived on a CIFS mount from vm102
(`mp0`: `/mnt/smb/vaultwarden` -> `/opt/vaultwarden`), the layout
[KE-5](../platform/known-errors.md#ke-5) recorded as a breach of the no-databases-on-CIFS rule.

Measured 2026-09-01, before deciding:

| Evidence | Value |
|---|---|
| `db.sqlite3` last modified | 2026-02-16 |
| Total data | 677 KB |
| Contents | one account |
| Image | `vaultwarden/server:latest`, not re-pulled since June |
| Guest backup | absent from the vzdump guest list until 2026-09-01 |
| Consistent export | never existed |
| Protection | SnapRAID parity only, side files excluded since [KE-19](../platform/known-errors.md#ke-19) |

The service was unused, unpatched and unbacked. A credential store nobody logs into is a target
nobody watches. ISO/IEC 27001 A.8.10 asks that information no longer required be deleted, A.5.9
that the asset inventory be current.

## Options
- **Keep it as it was.** Lost: a secrets tier in name, without a current, restorable copy.
- **Build the missing export** (SQLite online-backup API on a timer, plus a staleness alert). Lost:
  real work for a service nobody used.
- **Migrate to PostgreSQL on lxc260**, which is dumped nightly and restore-tested monthly. Lost for
  now: about a day of work with a credential-store data migration; kept as the reopening path.
- **Decommission in two phases.** Chosen.

## Decision
Retiring the service and destroying its data are separate acts.

- **Phase 1, 2026-09-01.** The whole guest stopped (not just the container), `onboot` cleared, a
  cold archive of the full file set taken while nothing wrote, and the inventory entry, scrape
  target and HTTPS probe removed together, so `NodeDown` does not fire for a node that is off by
  design.
- **Phase 2, executed 2026-09-29 and 2026-10-10.** `pct destroy 240` on 2026-09-29. It left `240`
  in the guest backup list, so the weekly job failed on a missing CTID until `GuestBackupPartial`
  was read on 2026-10-07. On 2026-10-10 the rest went: the share data and the share, its Samba and
  Linux accounts on vm102, the hypervisor's fstab entry and credentials, the `vzdump-lxc-240-*`
  archives, `host_vars/lxc240.yml`, the Compose directory and the `storage_permissions` entry. The
  tailnet node is no longer visible from the control node (read 2026-10-12).

The cold archive stays in `/root` on the hypervisor and on the off-site workstation until
2026-11-30 and is deleted from both that day.

Vaultwarden encrypts vault items client-side, so the archive holds ciphertext and account metadata,
not secrets. Confirmed 2026-09-01: nothing in the vault was still needed; the credentials that
matter are in the external password manager and the paper escrow
([remediation plan](../platform/remediation-plan.md)). No client export was taken.

## Consequences
- KE-5 is closed by removing its subject, not by solving SQLite on CIFS.
- Credential escrow is a single mechanism now; its annual retrieval drill is the only evidence it
  works.
- One fewer service to patch, probe, certify and back up.
- Reopening a secrets store goes through PostgreSQL on lxc260, with the phase-1 archive as input
  while it is retained and the master password still exists.

## Evidence

Recorded 2026-09-01:

- `pct status 240` reported `stopped`, `pct config 240` reported `onboot: 0`.
- The cold archive holds the raw file set and a checkpointed copy; `PRAGMA integrity_check` `ok`;
  identical `sha256` on the hypervisor and the off-site workstation.
- After re-rendering Prometheus from the role: 18 active targets, none unhealthy, no firing alert.

`db.sqlite3` (mtime 2026-02-16) sat next to a 57712-byte `db.sqlite3-wal` written 2026-06-11. On a
local copy `PRAGMA wal_checkpoint(TRUNCATE)` returned `(0, 0, 0)` and `integrity_check` returned
`ok`: the log held no frames, the database file was complete. A checkpointed WAL is not truncated, so
a stale log and a real backlog look the same from the filesystem. Both side files survived a graceful
`pct shutdown`, which points to untidy closes by the nightly host power cycle - relevant for any
future SQLite on CIFS.

## Related Documents
- [Known Errors](../platform/known-errors.md)
- [Data Classification](../platform/data-classification.md)
- [Remediation Plan](../platform/remediation-plan.md)
