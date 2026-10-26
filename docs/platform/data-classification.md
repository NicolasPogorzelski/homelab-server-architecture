# Data Classification and Recovery Objectives

What data this platform holds, how much its loss would cost, how it is protected today, and the
recovery objectives the backups are measured against. The class of each dataset sets the scope of
the [off-site backup](remediation-plan.md#off-site-backup).

## Classification scheme

| Level | Definition | Consequence of loss |
|---|---|---|
| **C1 - Critical** | Unrecoverable by any means, or contains personal data of identifiable people | Permanent; cannot be recreated by effort |
| **C2 - Important** | Recreatable at a cost of days of work | Expensive and disruptive, not permanent |
| **C3 - Replaceable** | Reacquirable, regenerable, or of historical interest only | Inconvenient |

Disclosure and loss share one axis: with no external data sharing, the datasets that would hurt
most if disclosed are the ones that would hurt most if lost.

## What this platform holds

| Dataset | Where it lives | Class | Personal data | Protection today |
|---|---|---|---|---|
| Ansible vault password, real inventory, Ansible SSH key | lxc250 home directory, on the boot SSD | C1 | No | Escrowed off site; never restored from ([drill](../../runbooks/platform/escrow-restore-drill.md)) |
| Paperless documents (originals and archive) | `/mnt/smb/paperless` on the archive pool | C1 | Yes - identity documents, contracts, invoices | SnapRAID parity only |
| Nextcloud user files | `/mnt/smb/nextcloud` on the archive pool | C1 | Yes | SnapRAID parity only |
| Nextcloud MariaDB | Inside lxc210, on the boot SSD | C1 | Yes | Daily verified dump to the `DB-Backups` share on vm102, monthly restore test (`mariadb_backup`, `mariadb_restore_test`) |
| Documents open in Collabora Online | Transient, in the CODE process's jails under `/tmp` in lxc210 | C1 while open | Yes | None needed; the durable original is the Nextcloud row. The process runs without seccomp and capability jailing ([service document](../services/nextcloud.md)) |
| Paperless metadata (`paperless_db`) | PostgreSQL on lxc260 | C2 | Yes, indirectly | Daily verified dump, monthly restore test (`postgresql_backup`, `postgresql_restore_test`) |
| Other application databases (`openwebui_db` and peers) | PostgreSQL on lxc260 | C2 | Minimal | Same dump |
| Guest root disks (search indexes, dashboards, application configuration) | `pve/data` thin pool on the boot SSD | C2 | Indirectly | Weekly `vzdump` of all nine guests to the aux-disk (`guest_backup`) |
| Platform configuration and documentation | This repository on GitHub and two workstations | C2 | No | Git; the only dataset with a running off-site copy |
| Monitoring history | Prometheus on lxc200 | C3 | No | None |
| Media library | Archive pool on vm102 | C3 | No | SnapRAID parity |
| Container images and Docker data roots | aux-disk | C3 | No | None; rebuilt from the compose files |

Dumps are kept for seven days (`RETENTION_DAYS=7` in
[`pg-backup.sh`](../../snippets/postgres/pg-backup.sh) and
[`mariadb-backup.sh`](../../snippets/mariadb/mariadb-backup.sh)); `find -mtime +7` deletes a dump
only once it is more than eight full days old.

**Parity:** SnapRAID protects against the loss of a disk. Deletion, corruption and
encryption by ransomware are legitimate writes to the array, and the next `snapraid sync` copies
them into the parity. Paperless documents and Nextcloud files have that protection and no other.

Nextcloud is split across two disks. Its files sit on the archive pool, its database on the
boot SSD of [KE-14](known-errors.md#ke-14). Without the database the files are blobs in Nextcloud's
storage layout with no owner, share or name, so the database's RPO must not exceed the files'.

## Recovery objectives

RPO (Recovery Point Objective) is how much data may be lost, measured in time; it is set by backup
frequency. RTO (Recovery Time Objective) is how long restoration may take; it is set by procedure
and hardware availability. "Of uptime" means the host's powered-on hours: the host is off every
night, and a job missed while it is off runs at the next boot.

| Dataset | RPO today | RPO target | RTO target | Note |
|---|---|---|---|---|
| Vault password and automation credentials | Escrow; the content changes rarely | Effectively zero | Immediate | The objective is availability, not freshness; only the drill proves it |
| Paperless documents | No backup | 24 h | 24 h | Parity only, on site |
| Nextcloud files | No backup | 24 h | 24 h | Parity only, on site |
| Nextcloud MariaDB | 24 h of uptime | 24 h | 8 h | Must not exceed the files' RPO |
| PostgreSQL cluster | 24 h of uptime | 24 h of uptime | 8 h | The staleness alert cannot see a period in which the host is off, because Prometheus runs on it |
| Guest root disks | One week | One week | 24 h | Restore per [`guest-backup-restore.md`](../../runbooks/platform/guest-backup-restore.md) |
| Platform configuration | Minutes | Keep | 1 h | Met by git |
| Media library | Not applicable | - | Best effort | Reacquisition, not restoration |

No platform-level RTO is stated. This is a single host without high availability; a hardware
loss is bounded by procurement, with lead times measured in weeks. The per-dataset objectives
assume working hardware. An outage of days in exchange for a simple, cheap platform is the
accepted trade for a small, closed set of users.

## Data protection assessment

The platform processes personal data: identity documents and correspondence in Paperless, files and
contacts in Nextcloud, and the viewing activity of the people who use the media services.

Article 2(2)(c) GDPR exempts processing "by a natural person in the course of a purely personal or
household activity". The platform sits close to two edges of that exemption:

- It ends when access is granted outside the household. The [ACL model](tailscale-acl.md)
  records one external user with access to Jellyfin, Audiobookshelf and Nextcloud through machine
  sharing. The assessment for those three services is due again and has not been redone
  ([remediation plan](remediation-plan.md)).
- It never covers the security obligation in practice. The data belongs to identifiable people
  who did not choose this platform's controls.

The C1 rows are therefore handled as though Article 32 applied, which their loss consequences
demand independently.

## Retention and deletion

No retention period exists for documents, logs or monitoring history; the only rule is the dump
retention above. No deletion procedure exists for media leaving the site, and the next one is due:
the aux-disk holds C1 application data and cannot be assumed erasable by software, since thousands
of its sectors are unreadable ([KE-13](known-errors.md#ke-13)). Both are open items in the
[remediation plan](remediation-plan.md).

## Off-site scope

The off-site backup copies the C1 rows that live on this platform: Paperless documents, Nextcloud
files and the two dump sets. C2 is either already off site through git or reconstructible from C1
plus this repository. C3 is excluded; copying the media archive would dominate the cost and
protect nothing that matters. The target is decided in
[`offsite-backup-target.md`](../decisions/offsite-backup-target.md).

Verified 2026-09-01: the C1 set on this platform is under 100 GB.

## Point-in-time copies off site

No running job copies anything off site. Two point-in-time copies exist:

| Copy | Location | Taken | What it covers |
|---|---|---|---|
| Auxiliary disk rescue | Encrypted storage on an admin workstation, in a different building from the server | 2026-06-25 | The failing aux-disk's contents at that date |
| Mirror disk | A second site, air-gapped | May 2026 | The guest root filesystems, and the databases inside them; not the archive pool, so no Nextcloud file, Paperless document or dump set |

Neither has been restored from, and neither can be given a cadence. They do not close the off-site
item.

## Review

Revisited with the weekly fleet audit. A new service adds its datasets to the table above in the
same pull request as its service document. The protection and RPO columns are the ones that change.
