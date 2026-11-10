# The Former Boot SSD Holds Data Whose Loss Costs Nothing

## Status
Implemented 2026-10-27. Supersedes / superseded by: -.

## Context
The volume group `pve` moved to an NVMe disk on 2026-10-27
([boot disk replacement](../../runbooks/platform/boot-ssd-replacement.md)). The former boot SSD,
a Samsung 840 EVO 120 GB, stays fitted on the SAS HBA at `9:0:0:0`, the port where
[KE-14](../platform/known-errors.md#ke-14) logged its `DID_SOFT_ERROR` bursts. Measured that day:
59,327 power-on hours, `Wear_Leveling_Count` normalised 045, about 84 TB written, no reallocated
sectors.

Two loads had no good home. Jellyfin's cache (image cache and transcodes, 1.3 GB) wrote to
`/mnt/vm-data`, a qcow2 image on the aux-disk with a growing count of unreadable sectors
([KE-13](../platform/known-errors.md#ke-13)). Disposable guests for the exercises before Terraform
([exercise scope](exercise-scope-before-terraform.md)) would land in `pve/data`, the pool every
production guest depends on.

## Options
- **Leave the SSD idle.** Costs nothing, and both loads stay where they are.
- **Durable data such as Docker data roots or database files.** The drive is worn and sits on the
  port with unexplained transport faults; a loss there would cost data.
- **The whole SSD as a second disk of vm100 for Jellyfin's cache.** One purpose, and the test
  guests still compete with production in `pve/data`.
- **A separate thin pool `scratch` for losable data: Jellyfin's cache and disposable guests.**
  Chosen.

## Decision
The SSD carries one GPT partition with the volume group `scratch` and the thin pool `scratch/data`
(104 GiB), registered in Proxmox as the `lvmthin` storage `scratch`. Only data that can be thrown
away goes there: vm100's `scsi2` (32 GiB, `backup=0`), mounted at `/mnt/scratch` and holding
`JF_CACHE`, and disposable guests. Nothing on `scratch` is backed up.

## Consequences
- A full `scratch` pool pauses every VM with a disk in it, vm100 included. The pool is not
  overcommitted: the virtual sizes of its volumes stay below 104 GiB. `lvm-thin-metrics` reports
  it with a `vg="scratch"` label, so the `LvmThinPool*` alerts cover it.
- `docker.service` on vm100 requires `/mnt/scratch` (`docker_mount_ordering`), so Jellyfin never
  writes its cache into the root disk. The price: a dead SSD keeps all of vm100's containers down
  until the mount line is removed and `JF_CACHE` points back to `/mnt/vm-data`.
- The SSD stays on the HBA port of KE-14; faults there hit a disk whose content is losable,
  and its `9:0:0:0` count keeps the transport evidence.
- A package cache for the [package supply track](../platform/remediation-plan.md#package-supply-track)
  can use the same pool.
