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
