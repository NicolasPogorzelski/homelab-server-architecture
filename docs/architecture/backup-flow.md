# Backup and Recovery Flow

What is copied, to where and how often, and what is not copied at all. Arrows follow the payload:
a dump moves from the database that produced it to the share that stores it. Schedules are in the
role defaults (`postgresql_backup`, `mariadb_backup`, `guest_backup` and the restore-test roles).

Red marks the copy that does not exist yet, the
[off-site backup](../platform/remediation-plan.md#off-site-backup). Orange marks copies on the
failing aux-disk ([KE-13](../platform/known-errors.md#ke-13)).

```mermaid
flowchart LR
  accTitle: Backup flows and the gaps in them
  accDescr: PostgreSQL and MariaDB dumps to SMB shares on vm102, each with a monthly restore test, weekly guest backups and daily host configuration archives onto the aux-disk, and the missing off-site copy marked as a gap.

  PG["lxc260 PostgreSQL<br/>pg_dumpall, nightly"]
  MDB["lxc210 Nextcloud MariaDB<br/>mariadb-dump, nightly"]
  GUESTS["9 guest root disks<br/>vzdump, weekly"]
  HOSTCFG["host configuration<br/>daily archive"]
  NCF["Nextcloud files"]
  PPD["Paperless documents"]

  subgraph vm102["vm102 archive pool - protected by SnapRAID parity, and by nothing else"]
    PGSHARE["Postgres-backups share<br/>verified, 8 day retention"]
    DBSHARE["DB-Backups share<br/>verified, 8 day retention"]
    LIVE["live data<br/>Nextcloud files, Paperless documents"]
  end

  VZDUMP["/mnt/vzdump on the aux-disk"]
  BOOTCOPY["/var/backups/host-config<br/>on the boot SSD"]
  RESTORE["monthly restore test<br/>throwaway cluster on port 5433"]
  MRESTORE["monthly restore test<br/>throwaway database"]
  OFFSITE["off-site copy<br/>does not exist"]

  PG -->|"dump"| PGSHARE
  MDB -->|"dump"| DBSHARE
  NCF --> LIVE
  PPD --> LIVE
  GUESTS -->|"snapshot mode"| VZDUMP
  HOSTCFG --> VZDUMP
  HOSTCFG --> BOOTCOPY

  PGSHARE -->|"newest dump"| RESTORE
  DBSHARE -->|"newest dump"| MRESTORE
  vm102 -.->|"planned"| OFFSITE

  classDef src fill:#0b3d6b,stroke:#062a4b,color:#ffffff
  classDef store fill:#6a4a9c,stroke:#4c3570,color:#ffffff
  classDef ok fill:#1f6f43,stroke:#14512f,color:#ffffff
  classDef warn fill:#8a5a00,stroke:#5f3e00,color:#ffffff
  classDef gap fill:#7a1f1f,stroke:#571414,color:#ffffff
  class PG,MDB,NCF,PPD,GUESTS,HOSTCFG src
  class PGSHARE,DBSHARE,LIVE,BOOTCOPY store
  class RESTORE,MRESTORE ok
  class VZDUMP warn
  class OFFSITE gap
```

## What the Picture Shows

**Both database chains are verified at write time.** Each dump is written under a `.partial` name
and renamed only after three checks pass: non-empty, `gzip -t`, and exactly one completion marker.
The marker check is the one that catches a dump killed halfway, which is still valid gzip. The
checks run before the retention delete, so a failed run never removes the last good dump.

**Both chains are restored monthly.** The PostgreSQL dump goes into a throwaway cluster on port 5433,
the MariaDB dump into a throwaway database; neither touches the live database. Results feed
`PostgreSQLRestoreTestStale` and `MariaDBRestoreTestStale`.

**The guest backup shares a disk with what it would rebuild.** `guest_backup` writes a weekly
`vzdump` of all nine guests to `/mnt/vzdump` on the aux-disk, lxc250 first. vm100 contributes its
root disk only; its `jellyfin-data` disk carries `backup=0`. A restore was verified on 2026-08-21
([guest backup runbook](../../runbooks/platform/guest-backup-restore.md)). The host's configuration
is archived daily to the same disk and to the boot SSD, so either survives the loss of the other
([platform restore](../../runbooks/platform/platform-restore.md)).

**Nothing is copied off site.** Every arrow ends inside the building. The archive pool holds the
backups and the primary data of two services, so fire, theft or encryption takes originals and
copies together. What exists elsewhere is point in time: this repository, the escrowed Ansible
secrets, and the irregular disk copies listed in
[data classification](../platform/data-classification.md), none of which covers the archive pool.
The `offsite_backup` role exists; its target is not provisioned.

## Parity Is Not Backup

Everything inside the vm102 box, dumps included, is protected by SnapRAID parity against a failed
disk, and against nothing else. Parity does not reconstruct a
file deleted, truncated or encrypted before the next `snapraid sync`, because that sync writes the
damage into the parity.

A file that changes while the sync reads it leaves parity inconsistent for that block
([KE-19](../platform/known-errors.md#ke-19)). SQLite side files (`*-shm`, `*-wal`) and other
volatile paths are therefore excluded in `snapraid_maintenance` defaults.

## The Guards and Their Shared Blind Spot

| Alert | Fires when | Blind to |
|---|---|---|
| `PostgreSQLBackupStale` | no verified dump for 25 h | an outage in which the host is off |
| `MariaDBBackupStale` | the same, for lxc210 | the same |
| `PostgreSQLRestoreTestStale` | no successful restore test for 40 days | - |
| `MariaDBRestoreTestStale` | the same, for MariaDB | - |
| `DatabaseBackupMetricsMissing` | a backup or restore-test timestamp is absent | - |
| `GuestBackupStale` | last guest backup run too old | - |
| `GuestBackupPartial` | at least one guest failed in the last run | - |
| `HostConfigBackupStale` | the host configuration archive is too old | - |

Thresholds are in [monitoring](../platform/monitoring.md). Prometheus runs on the host that powers
down every night: during a multi-day outage there is no scrape, and at the next boot the timer's
`Persistent=true` catch-up refreshes the timestamp before anything is evaluated. The backup rules
therefore mean "no more than 25 hours of uptime without a dump". Host-off periods are the job of the
[external heartbeat](../platform/remediation-plan.md#external-heartbeat).

## Related

- [Failure domains](failure-domains.md) - which disk takes which dataset with it
- [Data classification](../platform/data-classification.md) - class and recovery objective per dataset
- [PostgreSQL backup](../../runbooks/database/pg-backup.md), [restore](../../runbooks/database/pg-restore.md), [MariaDB backup](../../runbooks/database/mariadb-backup.md)
