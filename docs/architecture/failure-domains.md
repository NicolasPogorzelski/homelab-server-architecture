# Failure Domains - What Dies With What

If a piece of hardware fails, what fails with it. Containment is ownership: what a device carries is
drawn inside it. Unlike the other views, the arrows here follow loss: "if the source fails, this is
the consequence".

None of the three domains is redundant. The platform has no high availability; recovery is
procedural.

## The Three Domains

```mermaid
flowchart TB
  accTitle: Failure domains of the platform
  accDescr: Boot disk, aux-disk and vm102 as three failure domains, with what each carries and what its loss causes.

  subgraph boot["boot disk - NVMe in the M.2 slot"]
    ROOTS["pve-data thin pool<br/>every VM and LXC root disk"]
    PVEROOT["pve-root and /boot/efi"]
    SECRETS["lxc250: vault password, real inventory,<br/>Ansible SSH key - escrowed off the platform"]
    NCDB["lxc210: Nextcloud MariaDB"]
  end

  subgraph auxd["aux-disk - /mnt/aux-disk - KE-13, unreadable sectors growing"]
    DROOTS["Docker data-roots<br/>lxc200, lxc211, lxc220, lxc230"]
    PGDATA["lxc260: PostgreSQL data directory"]
    VZDUMP["short-term backups - daily vzdump archives, 7 days"]
    MONDATA["lxc200: Prometheus TSDB,<br/>Grafana and Alertmanager state"]
    JELLY["vm100 scsi1 - jellyfin-data, qcow2"]
  end

  subgraph storagevm["vm102 - the storage VM"]
    ARCHIVE["archive pool: Paperless documents, Nextcloud files,<br/>database dumps, media library"]
    PARITY["SnapRAID parity - covers disk loss only"]
  end

  boot --> L1["Total platform loss.<br/>No guest starts. Rebuild from the guest backups,<br/>the escrowed secrets and the repository."]
  auxd --> L2["Docker state, the PostgreSQL data directory,<br/>vm100's data disk, the metric history<br/>and every guest backup are lost.<br/>Databases restore from the dumps on vm102."]
  storagevm --> L3["All file data and dumps unreachable.<br/>Parity does not survive VM loss,<br/>deletion, corruption or ransomware."]

  classDef sick fill:#7a1f1f,stroke:#571414,color:#ffffff
  classDef warn fill:#8a5a00,stroke:#5f3e00,color:#ffffff
  classDef content fill:#0b3d6b,stroke:#062a4b,color:#ffffff
  class L1,L3 sick
  class L2 warn
  class ROOTS,PVEROOT,SECRETS,NCDB,DROOTS,PGDATA,VZDUMP,MONDATA,JELLY,ARCHIVE,PARITY content
```

## What Each Domain Means in Practice

**Boot disk.** It carries `/boot/efi`, `pve-root` and the whole `pve-data` thin pool, so every root
disk on the platform. It is an NVMe drive on PCIe; the former boot SSD, whose `DID_SOFT_ERROR`
bursts on the SAS HBA are [KE-14](../platform/known-errors.md#ke-14), stays fitted outside the
volume group ([proxmox-host.md](../platform/proxmox-host.md#boot-disk)).

Two [C1](../platform/data-classification.md) datasets sit on it: lxc250's Ansible secrets and
Nextcloud's MariaDB. MariaDB has a nightly verified dump on vm102 and a monthly restore test. The
secrets are escrowed in an external password manager and on paper; the escrow has
not been restored from ([escrow drill](../platform/remediation-plan.md#escrow-restore-drill)). The
host's own configuration is archived daily to the aux-disk and to the boot disk.

**aux-disk.** In service with a growing count of unreadable sectors
([KE-13](../platform/known-errors.md#ke-13) holds the measurements). `smartctl -H` reports PASSED
regardless, because `Current_Pending_Sector` cannot trip the self-assessment;
`SmartAttributeDegrading` watches the raw counts instead.

- Docker images and state: class C3, rebuildable from the compose files.
- PostgreSQL data directory: recovered from the newest nightly dump on vm102.
- Monitoring history: no backup.
- vm100's `jellyfin-data`: qcow2, so vm100 can be snapshotted; the snapshots of this disk live
  here, those of its system disk in the boot disk's thin pool, and they cover a bad change, not
  the disk's loss. The disk is excluded from the guest
  backup.
- `/mnt/vzdump` and the application archives on `jellyfin-data`: the short-term backups share this
  disk with the state they would rebuild; the monthly Backup-Archive on vm102 is the copy that
  survives it ([backup and recovery](backup-flow.md)).

Replacement: [aux-disk replacement](../platform/remediation-plan.md#aux-disk-replacement-and-disposal).

**vm102.** SnapRAID computes parity over the present contents of the data disks. It reconstructs a
failed disk. It does not reconstruct a file deleted, truncated or encrypted before the next
`snapraid sync`, because that sync writes the damage into the parity. Against site loss it is worth
nothing: the parity disk is in the same machine. Each dataset's protection is drawn in
[backup and recovery](backup-flow.md).

## What Is Not a Failure Domain

The Proxmox host is a single point of failure - one machine, no cluster - but its loss is a hardware
problem and no data problem: the guests live on the disks above. A dead mainboard costs a
replacement and a rebuild ([platform restore](../../runbooks/platform/platform-restore.md)); a dead
boot SSD rolls every guest back to its last daily backup and each database to its last nightly dump.

## Related

- [Storage design](../platform/storage-design.md) - the layout these domains are cut from
- [Data classification](../platform/data-classification.md) - what each dataset is worth
- [Backup and recovery](backup-flow.md) - what protection exists per dataset
- [Remediation plan](../platform/remediation-plan.md) - the ordering of the work
