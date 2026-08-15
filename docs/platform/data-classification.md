# Data Classification and Recovery Objectives

Written 2026-08-15. First classification of the data this platform holds.

## Why this was missing, and what it blocked

Until now every dataset on this platform was handled identically. A scanned passport in Paperless
and a film in the media library received the same protection, the same retention and the same
attention — which in practice meant the protection appropriate to the film.

That is not only untidy. It blocked a decision that has been queued for months. The remediation
plan's Tier 1 #3 reads "off-site copy of the critical subsets", and the reason it has not moved is
that **"critical subset" was never defined**, so every attempt to start it turned into an
open-ended question about what to copy and how much it would cost. Classification is not
bureaucracy here; it is the missing input to a decision already on the list.

The same applies to recovery objectives. The backup programme is unusually well built — dumps
verified at write time, restores tested monthly, staleness alerted — and yet nobody could say
whether it is *adequate*, because no one had stated how much data loss is tolerable. A backup
cadence without a recovery point objective is a number with nothing to compare it to.

## Classification scheme

Three levels, on purpose. Schemes with five levels are abandoned within a year because the
boundaries stop being obvious.

| Level | Definition | Consequence of loss |
|---|---|---|
| **C1 — Critical** | Unrecoverable by any means, or contains personal data belonging to identifiable people | Permanent. Cannot be recreated by effort. |
| **C2 — Important** | Recreatable, but at a cost measured in days of work | Expensive and disruptive, not permanent. |
| **C3 — Replaceable** | Reacquirable, regenerable, or of purely historical interest | Inconvenient. |

Disclosure and loss are deliberately collapsed into one axis. With a single operator and no
external sharing, the datasets that would hurt most if disclosed are the same ones that would hurt
most if lost, and a second axis would add ceremony without changing any decision.

## What this platform holds

| Dataset | Where it lives | Class | Personal data | Protection today |
|---|---|---|---|---|
| Ansible vault password, real inventory, automation SSH key | lxc250 home directory, on the boot SSD | C1 | No | **None.** One copy. |
| Vaultwarden vault (all household credentials) | `/mnt/smb/vaultwarden` on the archive pool | C1 | Yes | Parity only. No export, no versions. |
| Paperless documents (originals and archive) | `/mnt/smb/paperless` on the archive pool | C1 | Yes — identity documents, contracts, invoices | Parity only. |
| Nextcloud user files | `/mnt/smb/nextcloud` on the archive pool | C1 | Yes | Parity only. |
| Nextcloud MariaDB | Inside lxc210, on the boot SSD | C1 | Yes | **None.** See below. |
| Paperless metadata (`paperless_db`) | PostgreSQL on lxc260 | C2 | Yes, indirectly | Nightly verified dump, ~8-day retention, monthly restore test. |
| Other application databases (`openwebui_db` and peers) | PostgreSQL on lxc260 | C2 | Minimal | Same dump. |
| Platform configuration and documentation | This repository — GitHub plus two workstations | C2 | No | Git. Distributed by nature, and the only dataset here with a genuine off-site copy. |
| Monitoring history | Prometheus on lxc200 | C3 | No | None. |
| Media library | Archive pool on vm102 | C3 | No | SnapRAID parity. |
| Container images and Docker data roots | aux-disk | C3 | No | None; rebuilt from the compose files. |

## Two findings that came out of building this table

**Parity is not backup, and three of the five C1 datasets rely on nothing else.** SnapRAID protects
against the loss of a *disk*. It does not protect against deletion, corruption, or encryption by
ransomware, because those are legitimate writes as far as the array is concerned, and the next
`snapraid sync` copies the damage into the parity. Between two syncs there is a recovery window;
after a sync there is none. Vaultwarden, Paperless documents and Nextcloud files currently have
that and only that.

**The Nextcloud database has no backup at all.** The remediation plan's Tier 1 #3 says "off-site
copy of the critical subsets (Vaultwarden export, Nextcloud DB, Paperless documents)", which reads
as though local copies exist and merely need to be duplicated elsewhere. For the Nextcloud MariaDB
that is not the case: no dump job exists in any role, script or unit in this repository, and the
2026-07-10 fleet crontab audit found no hand-written job either. The nightly `pg_dumpall` covers
lxc260 only — MariaDB runs inside lxc210 and is not a PostgreSQL cluster.

The consequence is worse than it first looks. Nextcloud's files sit on the archive pool while its
database sits on the boot SSD, the disk with the unresolved [KE-14](known-errors.md#ke-14) I/O
faults. Losing that SSD leaves every user file intact and unusable: without the database, the
files are opaque blobs in Nextcloud's storage layout, with no owner, no share, and no name that
Nextcloud will recognise. **The two halves of one dataset are on different disks with different
protection, and the weaker half is the one that makes the other meaningful.**

This should be verified live on the node before being treated as final — the evidence here is the
absence of a job in the repository plus a month-old audit, not a fresh measurement.

## Recovery objectives

Two definitions, because the terms are routinely swapped. **RPO** (Recovery Point Objective) is how
much data may be lost, measured in time — it is a property of backup frequency. **RTO** (Recovery
Time Objective) is how long restoration may take — a property of procedure and hardware
availability.

| Dataset | RPO today | RPO target | RTO target | Note |
|---|---|---|---|---|
| Vault password and automation credentials | Unbounded — a single copy | Effectively zero | Immediate | The content changes approximately never; the objective is availability, not freshness. |
| Vaultwarden vault | Undefined | 24 h | 4 h | Everything else depends on being able to authenticate. |
| Paperless documents | Undefined | 24 h | 24 h | Originals are also held on paper for a subset. |
| Nextcloud files | Undefined | 24 h | 24 h | |
| Nextcloud MariaDB | Unbounded — no backup | 24 h | 8 h | Must not exceed the files' RPO, or restored files reference rows that do not exist. |
| PostgreSQL cluster | 24 h **of uptime** | 24 h of uptime | 8 h | The distinction is measured, not theoretical: the staleness alert cannot see a period in which the host is off, because Prometheus is on that host. |
| Platform configuration | Minutes | Keep | 1 h | Already met by git. |
| Media library | Not applicable | — | Best effort | Reacquisition, not restoration. |

**The platform-level RTO is deliberately not stated**, and stating one would be dishonest. This is a
single host with no high availability by design; a hardware loss is bounded by procurement, and the
current hardware order has a lead time measured in weeks. The per-service objectives above assume
functioning hardware. The recovery-oriented architecture is the accepted trade: cheap and simple in
exchange for an outage measured in days rather than minutes, which is the correct trade for a
platform whose consumers are one household.

## Data protection assessment

The platform processes personal data: identity documents and correspondence in Paperless, files and
contacts in Nextcloud, credentials in Vaultwarden, and viewing activity for two household members
who use the media services from their own televisions.

**Article 2(2)(c) GDPR exempts processing "by a natural person in the course of a purely personal
or household activity"**, and that is what this is. The assessment is recorded rather than assumed,
because the exemption is narrower than it is usually taken to be and this platform sits close to
two of its edges:

- **It ends the moment access is granted outside the household.** Sharing a Nextcloud folder with
  someone outside it, or opening a service to a friend, moves the processing out of the exemption —
  and would do so silently, since nothing in the platform would behave differently.
- **It never covers the security obligation in practice.** Even where the exemption applies, the
  data belongs to identifiable people who did not choose this platform's controls. The household
  members did not consent to a threat model; they simply watch television.

Treated here as a design constraint rather than a legal question: the C1 rows are handled as though
Article 32 applied, which is also what their loss consequences demand independently.

## Retention and deletion

Unresolved, and named here so it stops being invisible. There is no retention period for anything —
not for documents, not for logs, not for backups beyond the 7-day dump rotation, and not for the
monitoring history. There is likewise no deletion procedure for media leaving the flat, which
becomes concrete at the next hardware replacement: the failing aux-disk holds C1 application data
and cannot be assumed erasable by software, since 7680 of its sectors are unreadable.

Both are tracked in the [remediation plan](remediation-plan.md) rather than solved here.

## What this changes downstream

1. **Tier 1 #3 now has a defined scope**: the five C1 rows, and nothing else. The C2 rows are
   already off-site via git or reconstructible from the C1 rows plus this repository. The C3 rows
   are explicitly excluded — copying a media archive off-site would dominate the cost of the whole
   exercise and protect nothing that matters.
2. **Two of those rows need a local backup before an off-site copy is even meaningful.** The
   Nextcloud database has none, and Vaultwarden has no consistent export — an SQLite file copied
   from a live CIFS mount is not a backup, it is a gamble on timing.
3. **The next measurement is size.** Choosing an off-site target requires knowing the volume of the
   C1 set, which nobody has measured. Until that number exists, the choice between an encrypted
   object store, a rotated external disk kept elsewhere, and a self-hosted target is unanswerable.

## Review

Revisited with the weekly fleet audit, and whenever a new service is added — step 2 of the
new-service procedure in `CLAUDE.md` should be read as including a row in the table above.
Classification is stable; the protection and RPO columns are what change, and they change most
often by something being switched off.
