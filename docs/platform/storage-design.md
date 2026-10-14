# Storage Design

The storage layer is implemented as a dedicated VM to enforce separation of concerns between compute, storage and services.

## Technologies

- MergerFS (pooled storage abstraction)
- SnapRAID (parity-based data protection)

## Design Principles

- Clear separation between compute and storage responsibilities
- Explicit mount management (predictable boot behavior)
- Read-only access for consumer services where possible
- Controlled write access for data-owning services

## Data Protection (Current State)

- Single parity disk via SnapRAID
- Daily sync, weekly scrub and daily status run from systemd timers via `snapraid-maintenance.sh`
  (schedules and scrub percentage in the `snapraid_maintenance` role defaults)
- `SnapRAIDSyncStale` fires after 26 hours without a sync, `SnapRAIDScrubStale` after 10 days
  without a scrub; coverage rules watch the oldest unscrubbed block ([monitoring.md](monitoring.md))

## Implementation Details

### Disk Layout

- Dedicated system disk (OS + swap)
- Multiple data disks formatted with ext4
- One dedicated parity disk
- Additional auxiliary disks for non-parity workloads

### Mount Strategy

- Persistent disk mapping via /dev/disk/by-id on the hypervisor
- Individual mount points per disk (e.g. /mnt/disk01 ...)
- MergerFS pool mounted at /mnt/mergerfs
- ext4 mounted with performance-aware options (e.g. noatime)

### Operational Characteristics

- No application workloads on the storage VM
- Clear separation between storage and compute layers
- Read-only exports for consumer services where possible
- SnapRAID executed with root privileges

## Failure Domain

The storage VM (VM102) represents a single failure domain.

- All persistent service data depends on this VM.
- Failure of VM102 results in loss of SMB access and MergerFS namespace.
- Parity protects against individual disk failures, not VM-level outage.

High availability is not implemented; recovery is procedure-based.

---

## Technical Implementation (Current State)

### Disk Topology

Storage VM (VM102, Debian 12) uses a multi-disk layout:

- OS disk: `sda1` (ext4) mounted at `/`
- Data disks (SnapRAID data):
  - `disk01` -> `/mnt/disk01`
  - `disk02` -> `/mnt/disk02`
  - `disk03` -> `/mnt/disk03`
  - `disk04` -> `/mnt/disk04`
  - `disk05` -> `/mnt/disk05`
- Parity disk:
  - `parity1` -> `/mnt/parity`
- Auxiliary disk:
  - `aux-pool` -> `/mnt/aux-pool` (temporarily part of SnapRAID + MergerFS pool as capacity bridge; to be removed when disk06 is added)

`aux-pool` is temporarily included as a 6th data disk.

`aux-pool` is distinct from `aux-disk`, the application-data disk attached to the Proxmox host
([KE-13](known-errors.md#ke-13), [proxmox-host.md](proxmox-host.md)); vm102 has no aux-disk mount.

All data/parity disks are formatted as `ext4` and mounted persistently.

### SnapRAID Configuration

SnapRAID is used for parity-based protection (not real-time RAID).

Parity file:

- `parity /mnt/parity/snapraid.parity`

Content files (one per data disk, improves robustness and recoverability):

- `content /mnt/disk01/snapraid.content`
- `content /mnt/disk02/snapraid.content`
- `content /mnt/disk03/snapraid.content`
- `content /mnt/disk04/snapraid.content`
- `content /mnt/disk05/snapraid.content`
- `content /mnt/aux-pool/snapraid.content` (temporary, remove when disk06 added)

Data disks:

- `data disk01 /mnt/disk01`
- `data disk02 /mnt/disk02`
- `data disk03 /mnt/disk03`
- `data disk04 /mnt/disk04`
- `data disk05 /mnt/disk05`
- `data aux-pool /mnt/aux-pool` (temporary capacity bridge, remove when disk06 added)

Excludes are owned by the `snapraid_maintenance` role (`snapraid_excludes` in its defaults) through
a marked `blockinfile`; the layout above it stays hand-written because it carries real device labels:

- `exclude *.tmp`
- `exclude *.bak`
- `exclude lost+found/`
- `exclude /tmp/`
- `exclude /cache/`
- `exclude /Nextcloud/nextcloud.log` and `/Nextcloud/nextcloud.log.*`
- `exclude *.sqlite3-shm`, `*.sqlite3-wal`, `*.db-shm`, `*.db-wal` - the
  [KE-19](known-errors.md#ke-19) rules: a database side file captured at a different moment than
  its main file yields a parity set from which a reconstruction can be corrupt
- `exclude /Nextcloud/appdata_*/richdocuments/remoteData/` - Collabora scratch data

Operational note:
- `snapraid status` is typically executed with `sudo` because SnapRAID must read content/parity state files.

Important:

Data written after the last `snapraid sync` is not parity-protected.
Operational discipline (regular sync + scrub) is required to maintain protection guarantees.

### MergerFS (Unified View)

A MergerFS mount provides a single unified namespace across all data disks:

- Mountpoint: `/mnt/mergerfs`
- This is the base path for service directories (e.g. `Nextcloud`, `Paperless`, `Filme`, `Serien`, `Audiobooks`, `Books`).

MergerFS is used for:
- stable service paths (services do not care on which disk a file resides)
- flexible growth (add disks without changing service configs)

### Samba Share Model (Segmentation + Least Privilege)

Samba exports directories from `/mnt/mergerfs` with strict user separation.

Global settings (high-level):
- Standalone server, user-based auth
- SMB3 only (`server min/max protocol = SMB3`)
- Port 445 only (`smb ports = 445`)
- Mandatory signing (`server signing = mandatory`)

Service shares (read-write, per-service user): `[Nextcloud]`, `[Paperless]`, `[Postgres-backups]`,
`[DB-Backups]`, and the two Paperless ingest shares. The full list with paths is in
[samba.md](samba.md).

Owner mapping (current state for RW shares):
- `force user = storage`
- `force group = storage`
- `create mask = 0660`
- `directory mask = 0770`

Media shares:
- `[Filme]`, `[Serien]`, `[Audiobooks]`, `[Books]` -> RW for `storage` (`create mask = 0640`,
  `directory mask = 2750`)
- Read-only consumers, one share per library:
  - `[media-jf-filme]` -> `/mnt/mergerfs/Filme`, `[media-jf-serien]` -> `/mnt/mergerfs/Serien`
    (valid user: `<svc-jellyfin>`, RO, not browseable)
  - `[media-abs-audiobooks]` -> `/mnt/mergerfs/Audiobooks`, `[media-abs-podcasts]` ->
    `/mnt/mergerfs/Podcasts` (valid user: `<svc-audiobookshelf>`, RO, not browseable)
  - `[Books-service]` -> `/mnt/mergerfs/Books` (valid user: `<svc-books>`, RO, not browseable)

The filesystem side of this model - which group owns which directory, which modes are permitted,
where setgid must be set - is stated and verified separately in
[storage-permissions.md](storage-permissions.md); the share configuration alone does not determine
it.

Least privilege on both sides:
- Write: RW only for the service that owns the data, and for the admin workstation identity.
- Read: each consumer share is scoped to one library, so the boundary holds before any filesystem
  mode is evaluated.

### Mount Persistence (fstab + systemd)

MergerFS is defined in `/etc/fstab`, which makes the mount reboot-safe. On boot, systemd generates the mount unit automatically via `systemd-fstab-generator`:

- Generated unit: `/run/systemd/generator/mnt-mergerfs.mount`
- Mount: `/mnt/disk01:/mnt/disk02:/mnt/disk03:/mnt/disk04:/mnt/disk05:/mnt/aux-pool` -> `/mnt/mergerfs` (aux-pool temporary)
- Type: `fuse.mergerfs`
- Options (fstab): `defaults,allow_other,use_ino,category.create=mfs`

Effective runtime state can be inspected via:

- `findmnt -T /mnt/mergerfs -o TARGET,SOURCE,FSTYPE,OPTIONS`

Sanitized fstab excerpt is stored in:
- `snippets/storage/fstab.storage-vm102.sanitized.conf`
