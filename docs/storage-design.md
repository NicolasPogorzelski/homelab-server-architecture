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
- Manual synchronization during active data migration phase
- Regular status verification
- Scrubbing enabled and tracked

## Implementation Details

### Disk Layout

- Dedicated system disk (OS + swap)
- Multiple data disks formatted with ext4
- One dedicated parity disk
- Additional auxiliary disks for non-parity workloads

### Mount Strategy

- Persistent disk mapping via /dev/disk/by-id on the hypervisor
- Individual mount points per disk (e.g. /mnt/disk01 …)
- MergerFS pool mounted at /mnt/mergerfs
- ext4 mounted with performance-aware options (e.g. noatime)

### Operational Characteristics

- No application workloads on the storage VM
- Clear separation between storage and compute layers
- Read-only exports for consumer services where possible
- SnapRAID executed with root privileges

---

## Technical Implementation (Current State)

### Disk Topology

Storage VM (VM102, Debian 12) uses a multi-disk layout:

- OS disk: `sda1` (ext4) mounted at `/`
- Data disks (SnapRAID data):
  - `disk01` → `/mnt/disk01`
  - `disk02` → `/mnt/disk02`
  - `disk03` → `/mnt/disk03`
  - `disk04` → `/mnt/disk04`
  - `disk05` → `/mnt/disk05`
- Parity disk:
  - `parity1` → `/mnt/parity`
- Auxiliary disk:
  - `aux02tb` → `/mnt/aux3TB`

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

Data disks:

- `data disk01 /mnt/disk01`
- `data disk02 /mnt/disk02`
- `data disk03 /mnt/disk03`
- `data disk04 /mnt/disk04`
- `data disk05 /mnt/disk05`

Excludes (current state):

- `exclude *.tmp`
- `exclude *.bak`
- `exclude lost+found/`
- `exclude /tmp/`
- `exclude /cache/`

Operational note:
- `snapraid status` is typically executed with `sudo` because SnapRAID must read content/parity state files.

### MergerFS (Unified View)

A MergerFS mount provides a single unified namespace across all data disks:

- Mountpoint: `/mnt/mergerfs`
- This is the base path for service directories (e.g. `Nextcloud`, `Vaultwarden`, `Filme`, `Serien`, `Audiobooks`, `Books`).

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

Service shares (read-write, per-service user):
- `[Nextcloud]` → `/mnt/mergerfs/Nextcloud` (valid user: `nextcloud`, RW)
- `[Vaultwarden]` → `/mnt/mergerfs/Vaultwarden` (valid user: `vaultwarden`, RW)

Owner mapping (current state for RW shares):
- `force user = storage`
- `force group = storage`
- `create mask = 0660`
- `directory mask = 0770`

Media shares:
- `[Filme]`, `[Serien]`, `[Audiobooks]`, `[Books]` → RW for `storage`
- Read-only consumers:
  - `[media-jf]` → `/mnt/mergerfs` (valid user: `media-jf`, RO, not browseable)
  - `[media-abs]` → `/mnt/mergerfs` (valid user: `media-abs`, RO, not browseable)
  - `[Books-service]` → `/mnt/mergerfs/Books` (valid user: `books-svc`, RO, not browseable)

This model enforces least-privilege:
- RW only where needed (Nextcloud/Vaultwarden/service admin)
- RO for consumers (Jellyfin/Audiobookshelf/Calibre-Web)


### Mount Persistence (fstab + systemd)

MergerFS is defined in `/etc/fstab`, which makes the mount reboot-safe. On boot, systemd generates the mount unit automatically via `systemd-fstab-generator`:

- Generated unit: `/run/systemd/generator/mnt-mergerfs.mount`
- Mount: `/mnt/disk01:/mnt/disk02:/mnt/disk03:/mnt/disk04:/mnt/disk05` → `/mnt/mergerfs`
- Type: `fuse.mergerfs`
- Options (fstab): `defaults,allow_other,use_ino,category.create=mfs`

Effective runtime state can be inspected via:

- `findmnt -T /mnt/mergerfs -o TARGET,SOURCE,FSTYPE,OPTIONS`

Sanitized fstab excerpt is stored in:
- `snippets/storage/fstab.storage-vm102.sanitized.conf`
