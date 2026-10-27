# Runbooks

Operational procedures for recovery and maintenance. Every runbook follows the template in
[docs/CONVENTIONS.md](../docs/CONVENTIONS.md#runbook): a header with Use when, Duration, Risk and
Last exercised, then Preconditions, Steps with a check each, Verification, Failure modes and
Rollback. Where a step has no rollback, the runbook names its abort criteria instead. Related:
[Platform Operations](../docs/platform/operations.md).

## Platform

| Runbook | Use when | Last exercised |
|---|---|---|
| [platform-restore](platform/platform-restore.md) | The Proxmox host has to be rebuilt on a fresh install | never |
| [boot-ssd-replacement](platform/boot-ssd-replacement.md) | The boot disk is replaced by a disk fitted beside it | 2026-10-27, pass |
| [ke14-power-path-check](platform/ke14-power-path-check.md) | KE-14 errors persist and the 12 V power path is to be measured | never |
| [escrow-restore-drill](platform/escrow-restore-drill.md) | The yearly restore of the escrowed vault password, inventory and SSH key is due | never |
| [hard-shutdown-recovery](platform/hard-shutdown-recovery.md) | Guests fail to start after an unclean host shutdown | never |
| [host-console-gpu-swap](platform/host-console-gpu-swap.md) | A local console on the host is needed while the GPU is passed through to vm100 | never |
| [lvm-thin-pool-full](platform/lvm-thin-pool-full.md) | An `LvmThinPool*` alert fires or guests report I/O errors | 2026-04-25, pass (incident) |
| [docker-data-root-migration](platform/docker-data-root-migration.md) | An LXC keeps its Docker data root on the thin pool | 2026-04-30, pass |
| [backup-archive](platform/backup-archive.md) | Provisioning or checking the monthly Backup-Archive, restoring a month, or a `BackupMirror*` / `AppBackup*` alert fires | 2026-10-27, pass |
| [guest-backup-restore](platform/guest-backup-restore.md) | A guest has to be restored, or a `GuestBackup*` alert fires | 2026-08-21, pass |
| [lxc250-rebuild](platform/lxc250-rebuild.md) | The Ansible control node has to be recreated | never |
| [pveproxy-tailscale-boot-race](platform/pveproxy-tailscale-boot-race.md) | The web UI on `:8006` is down after boot while SSH works (KE-12) | 2026-06-25, pass |
| [offsite-vps-provision](platform/offsite-vps-provision.md) | The off-site backup VPS is built | never |

## Storage

| Runbook | Use when | Last exercised |
|---|---|---|
| [smb-autofs-trigger](storage/smb-autofs-trigger.md) | `smb-mounts-check.service` failed or a container sees an empty share | never |
| [snapraid-sync](storage/snapraid-sync.md) | Parity is needed before the next timer run, or `SnapRAIDSyncStale` fires | never |
| [snapraid-scrub](storage/snapraid-scrub.md) | A `SnapRAIDScrub*` alert fires or a scrub reported errors | never |
| [aux-disk-failure-rescue](storage/aux-disk-failure-rescue.md) | The host aux-disk logs medium errors or no longer mounts | 2026-06-25, applied (incident) |

## Backup and databases

| Runbook | Use when | Last exercised |
|---|---|---|
| [offsite-backup](backup/offsite-backup.md) | The `offsite_backup` role is deployed or an off-site restore is needed | never (VPS not provisioned) |
| [pg-backup](database/pg-backup.md) | The lxc260 backup is deployed or `PostgreSQLBackupStale` fires | 2026-08-14, pass |
| [pg-restore](database/pg-restore.md) | A database on lxc260 is lost or corrupt | 2026-08-13, pass; monthly restore test by timer |
| [mariadb-backup](database/mariadb-backup.md) | The lxc210 backup is deployed or `MariaDBBackupStale` fires | 2026-08-15, pass |
| [mariadb-restore](database/mariadb-restore.md) | Nextcloud's database on lxc210 is lost or corrupt | never on live; monthly restore test by timer |

## Services

| Runbook | Use when | Last exercised |
|---|---|---|
| [nextcloud-paperless](integration/nextcloud-paperless.md) | Documents from the Nextcloud Paperless Inbox do not reach Paperless | never |
| [openwebui-health](ai-stack/openwebui-health.md) | OpenWebUI on lxc230 is unreachable or errors | never |
