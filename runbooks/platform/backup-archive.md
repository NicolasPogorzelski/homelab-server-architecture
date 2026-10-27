# Runbook: Backup-Archive (monthly long-term tier)

- **Use when:** provisioning the Backup-Archive shares, running a mirror by hand, restoring from a
  month on the array, or `BackupMirrorStale` / `BackupMirrorFailed` / `AppBackupStale` fires.
- **Duration:** 45 minutes for provisioning both writers; a mirror run takes as long as copying one
  day of archives to vm102.
- **Risk:** low. The mirror only reads the short-term tier and writes into its own month directory.
  A share that is not mounted would send the copy to a local disk; the role and the script both
  refuse an unmounted target.
- **Last exercised:** 2026-10-27, pass (both writers provisioned; first mirror on the host and on
  vm100 verified with `sha256sum -c`)

Backups run in two tiers ([backup flow](../../docs/architecture/backup-flow.md)). The daily tier
sits on the aux-disk ([KE-13](../../docs/platform/known-errors.md#ke-13)): `guest_backup` on the
host, `app_backup` on vm100 for Jellyfin, and Audiobookshelf's own scheduled archive. The monthly
tier is this archive on the SnapRAID array.

| Parameter | Value |
|---|---|
| Writers | the hypervisor (`backup_mirror` in `group_vars/proxmox.yml`), vm100 (`host_vars/vm100.yml`) |
| Content | newest archive per source group: one vzdump per guest, the host configuration, Jellyfin, Audiobookshelf |
| Layout | `/mnt/mergerfs/Backup-Archive/{guests,apps}/<YYYY-MM>/<source>/`, `SHA256SUMS`, `.complete` |
| Verification | sha256 of source and copy compared per file before the month is renamed into place |
| Retention | three complete months (`backup_mirror_keep`); incomplete runs never count |
| Metrics | `backup_mirror_last_success_timestamp_seconds`, `backup_mirror_last_run_success` per node |

## Preconditions

- `storage_permissions` deployed on vm102 with the `Backup-Archive` entry.
- `vault_jellyfin_api_key` defined in the vaulted inventory (already used by `jellyfin_watchdog`).
- vm100 runs Jellyfin 10.11 or later (backup API) and the Audiobookshelf stack with
  `ABS_BACKUP_ROOT` in its `.env`.

## Steps

1. Create the two accounts and directories on vm102. The accounts have no shell and no home.
   ```bash
   sudo useradd -M -s /usr/sbin/nologin pve-mirror && sudo smbpasswd -a pve-mirror
   sudo useradd -M -s /usr/sbin/nologin vm100-mirror && sudo smbpasswd -a vm100-mirror
   sudo install -d -o storage -g storage -m 2770 /mnt/mergerfs/Backup-Archive/guests /mnt/mergerfs/Backup-Archive/apps
   ```
   Add the `[Backup-Archive-guests]` and `[Backup-Archive-apps]` stanzas from
   `snippets/storage/smb.conf.storage-vm102.sanitized.conf`, then
   `sudo testparm -s && sudo systemctl reload smbd`.
   Check: `testparm -s` lists both shares.

2. Store the `pve-mirror` password in a root-only credentials file on the hypervisor and add an
   fstab line modelled on the `DB-Backups` one, with `uid=0,gid=0` and mount point
   `/mnt/smb/backup-archive-guests`.
   ```bash
   mkdir -p /mnt/smb/backup-archive-guests && systemctl daemon-reload
   systemctl start "$(systemd-escape -p --suffix=automount /mnt/smb/backup-archive-guests)"
   findmnt -no FSTYPE,SOURCE /mnt/smb/backup-archive-guests
   ```
   Check: `cifs` and the `Backup-Archive-guests` share.

3. Repeat step 2 on vm100 for `vm100-mirror` at `/mnt/backup-archive-apps`, as a plain `.mount` unit
   modelled on `srv-media-audiobooks.mount` (read-write, `nofail`), enabled without an `.automount`
   and without `x-systemd.idle-timeout`, because an automatic unmount of a live CIFS mount is the
   fault in [KE-20](../../docs/platform/known-errors.md#ke-20).
   Check: `findmnt -no FSTYPE /mnt/backup-archive-apps` prints `cifs`.

4. Set `ABS_BACKUP_ROOT=/mnt/vm-data/backups/audiobookshelf` in
   `/opt/docker/audiobookshelf/.env` on vm100, then from lxc250 run `app-backup.yml` and
   `docker-compose-update.yml` with `--check --diff` first, then without.
   Check: `docker inspect audiobookshelf` lists the `/backups` bind.

5. Set Audiobookshelf's backup path with `PATCH /api/backups/path` (`{"path": "/backups"}`); the
   server settings endpoint ignores `backupPath`. Set `backupSchedule` `0 12 * * *` and
   `backupsToKeep` 7 with `PATCH /api/settings`, or both under Settings -> Backups.
   Check: an API backup (`POST /api/backups`) returns `200` and a file appears under
   `/mnt/vm-data/backups/audiobookshelf`.

6. Run `guest-backup.yml` and `backup-mirror.yml` from lxc250, `--check --diff` first.
   Check: `systemctl list-timers guest-backup.timer app-backup.timer backup-mirror.timer` on the
   host and vm100 shows the next runs.

7. Run the first mirror by hand on both writers: `systemctl start backup-mirror.service`.
   Check: `<target>/<YYYY-MM>/.complete` exists and `sha256sum -c SHA256SUMS` in that directory
   passes.

## Verification

- `backup_mirror_last_run_success` is 1 on the host and on vm100.
- `app_backup_last_archive_timestamp_seconds` is under a day old for both applications.
- No `BackupMirror*` or `AppBackup*` alert is active.

## Failure modes

- `ERROR: <target> is not mounted`: the share or its mount is missing; repeat step 2 or 3.
- The daily tier produced nothing for a source and the run prints `has no file matching`; check
  `guest-backup.service` or `app-backup.service` first. The month on the array is unchanged.
- Checksum mismatch: the copy is discarded with its `.incoming-<month>` directory and the run fails;
  the previous month stays the newest complete one.
- `AppBackupStale` for Jellyfin with `app-backup.service` failed on HTTP 401: the vault key no
  longer exists in Jellyfin.

## Rollback

Disable the timers (`systemctl disable --now backup-mirror.timer app-backup.timer`). The archive
directories hold only copies and can stay. To return the guest backup to its previous schedule,
revert the `guest_backup` defaults and script and rerun `guest-backup.yml`.

## Background

A month directory is written as `.incoming-<YYYY-MM>` and renamed only after every checksum
matched, and `.complete` marks it. Pruning counts only complete months, so a failed run can never
push out the last good one. A restore copies the archive from `<YYYY-MM>/<source>/` back to the short-term
location and follows [guest-backup-restore.md](guest-backup-restore.md) for a vzdump archive or
[platform-restore.md](platform-restore.md) for the host configuration; a Jellyfin archive is
restored with `--restore-archive <zip>` at Jellyfin's start, an Audiobookshelf archive through
Settings -> Backups -> Upload.
