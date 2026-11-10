# Runbook: Nextcloud -> Paperless-ngx ingestion - verify and repair

- **Use when:** `PaperlessIngestStorageDown` fires, a document dropped into a Nextcloud "Paperless
  Inbox" does not reach Paperless, the inbox shows a red storage icon, or it keeps listing
  documents Paperless already consumed.
- **Duration:** 10-20 minutes.
- **Risk:** low; no document is touched. Removing a consumption directory that already holds a file
  deletes an ingest in flight.
- **Last exercised:** never.

The pipeline spans three nodes: a Nextcloud External Storage mount per user on lxc210 writes over
SMB to `/mnt/mergerfs/Paperless/consumption/<user>` on vm102 (shares `Paperless-ingest-user1`,
`Paperless-ingest-user2`, SMB user `paperless-ingest`); Paperless on lxc211 consumes from
`/data/paperless/consumption` and deletes each file on the share. Nextcloud's file cache does not see
that deletion, so `paperless-inbox-scan.timer` (role `paperless_inbox_scan`, schedule in its
defaults) runs `occ files:scan` on every user's inbox.

lxc210 and lxc211 are containers (`pct exec` from the host). vm102 is a VM: commands run over SSH,
`ssh <user>@<tailscale-ip-storage>`, with `sudo`. In the commands below:

```bash
OCC="pct exec 210 -- runuser -u www-data -- php /var/www/nextcloud/occ"
```

## Preconditions

- vm102 is running and Samba is active: `ssh <user>@<tailscale-ip-storage> systemctl is-active smbd`.
- lxc210 and lxc211 are running; `pct exec 211 -- docker ps` shows `paperless` `Up`.
- The host's Paperless share is mounted: `findmnt -no FSTYPE /mnt/smb/paperless` prints `cifs`.

## Steps

1. Find the broken layer: run the [Verification](#verification) block and start at the first
   check that fails.
   Check: the failing check maps to one of steps 2-5.

2. Host SMB mount missing. Trigger the automount and read the result.
   ```bash
   ls /mnt/smb/paperless >/dev/null
   findmnt -no FSTYPE,SOURCE /mnt/smb/paperless
   ```
   Check: `cifs //<vm102>/Paperless`. Otherwise see [smb-autofs-trigger.md](../storage/smb-autofs-trigger.md);
   a container started while the mount was down needs `pct reboot 211` afterwards (KE-15).

3. Consumption directory missing. Paperless removes empty subdirectories after a full import cycle;
   recreate them on vm102 with the ownership the `storage_permissions` matrix requires.
   ```bash
   ssh <user>@<tailscale-ip-storage> \
     'sudo install -d -o storage -g storage -m 2770 /mnt/mergerfs/Paperless/consumption/user1 /mnt/mergerfs/Paperless/consumption/user2'
   ```
   Check: `pct exec 211 -- ls -la /data/paperless/consumption/` lists both directories.

4. External Storage mount stale (red icon). Verify, and if still failing, re-assign the user.
   Mount IDs: `4` = first user, `5` = second user.
   ```bash
   $OCC files_external:verify <mount-id>
   $OCC files_external:applicable --remove-user <user> <mount-id>
   $OCC files_external:applicable --add-user <user> <mount-id>
   ```
   Check: `files_external:verify <mount-id>` reports `status: ok`. Stop before re-assigning if vm102
   is unreachable; the fault is one layer down (step 2).

5. Inbox lists consumed documents. Run the rescan now instead of waiting for the timer.
   ```bash
   pct exec 210 -- systemctl start paperless-inbox-scan.service
   pct exec 210 -- systemctl show paperless-inbox-scan.service -p Result
   ```
   Check: `Result=success`; the consumed documents are gone from the inbox in the web interface.

## Verification

```bash
findmnt -no FSTYPE /mnt/smb/paperless
pct exec 211 -- ls -la /data/paperless/consumption/
$OCC files_external:verify 4
$OCC files_external:verify 5
pct exec 211 -- docker logs paperless --tail 20
pct exec 210 -- systemctl list-timers paperless-inbox-scan.timer
```

Expected: `cifs`; both consumption directories exist; both mounts `status: ok`; the Paperless log
shows the consumer polling; the scan timer shows a `NEXT` time. End to end: upload a test PDF into
one inbox, it appears in Paperless and leaves the inbox after the next scan.

## Failure modes

| Symptom | Cause | Action |
|---|---|---|
| Red icon on Paperless Inbox | Consumption directory deleted or SMB down | Step 3 or step 2 |
| Upload not appearing in Paperless | Consumer polling delay or directory missing | Wait a minute; step 3 |
| Consumed document still in the inbox | Cache not yet rescanned | Step 5 |
| `files_external:verify` error | Share unreachable or `paperless-ingest` credentials wrong | Check Samba on vm102 and the SMB user |
| Paperless logs permission errors | Ownership on the consumption directory | `force user`/`force group` in vm102 `smb.conf`; `storage-permissions.service` result |
| Scan unit failed | MariaDB or Apache down on lxc210 | `pct exec 210 -- journalctl -u paperless-inbox-scan.service` |

## Rollback

- Step 3: the directories are created empty; removing them restores the previous state. Check first
  that Paperless has not consumed something into them.
- Step 4: only the user assignment is removed and re-added; the mount definition and its
  credentials are untouched. Re-adding the original assignment is the reversal.
- Steps 2 and 5 change no state.

## Background

Adding a user needs a new ingest share on vm102 (`snippets/storage/smb.conf.storage-vm102.sanitized.conf`),
a new External Storage mount in Nextcloud and a Paperless workflow; the scan picks up new users
automatically through `occ user:list`. See [paperless.md](../../docs/services/paperless.md) and
[nextcloud.md](../../docs/services/nextcloud.md).
