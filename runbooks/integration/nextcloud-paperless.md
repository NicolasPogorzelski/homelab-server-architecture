# Runbook: Nextcloud → Paperless-ngx ingestion — verify and repair

## Problem

The Nextcloud → Paperless ingestion pipeline spans three systems (LXC210, VM102, LXC211)
and can break silently at several points:

- Nextcloud External Storage mount becomes unavailable (red icon)
- Consumption subdirectories deleted by Paperless after a full import cycle
- Nextcloud file cache shows stale/deleted documents
- SMB share unreachable or credentials expired

## Preconditions

- VM102 is running and Samba is active
- LXC210 (Nextcloud) is running
- LXC211 (Paperless) is running and healthy
- Proxmox host SMB automounts are active (`/mnt/smb/paperless`)

---

## Verification (end-to-end check)

```bash
# 1. Confirm consumption directories exist on VM102
pct exec 211 -- ls -la /data/paperless/consumption/

# 2. Confirm Nextcloud External Storage mounts are reachable (status: ok)
pct exec 210 -- su -s /bin/bash -c \
  "php /var/www/nextcloud/occ files_external:verify 4" www-data
pct exec 210 -- su -s /bin/bash -c \
  "php /var/www/nextcloud/occ files_external:verify 5" www-data

# 3. Confirm Paperless consumer is running
pct exec 211 -- docker logs paperless --tail 20

# 4. Confirm cache sync cronjob is active on LXC210
pct exec 210 -- crontab -l -u root | grep scan-paperless
```

Expected: consumption dirs exist, both mounts return `status: ok`, Paperless logs show
consumer polling, crontab shows hourly `scan-paperless-inbox.sh` entry.

---

## Recovery

### A — Consumption subdirectories missing

Paperless deletes empty subdirectories after a full import cycle. Recreate them on VM102:

```bash
pct exec 102 -- bash -c "
  mkdir -p /mnt/mergerfs/Paperless/consumption/<user1>
  mkdir -p /mnt/mergerfs/Paperless/consumption/<user2>
  chmod 770 /mnt/mergerfs/Paperless/consumption/<user1>
  chmod 770 /mnt/mergerfs/Paperless/consumption/<user2>
"
```

Then re-verify Nextcloud mounts (step 2 above).

### B — Nextcloud External Storage mount stale (red icon)

```bash
# Re-verify mount
pct exec 210 -- su -s /bin/bash -c \
  "php /var/www/nextcloud/occ files_external:verify <mount-id>" www-data

# If still unavailable — remove and re-add user assignment
pct exec 210 -- su -s /bin/bash -c \
  "php /var/www/nextcloud/occ files_external:applicable --remove-user <user> <mount-id>" www-data
pct exec 210 -- su -s /bin/bash -c \
  "php /var/www/nextcloud/occ files_external:applicable --add-user <user> <mount-id>" www-data

# Confirm
pct exec 210 -- su -s /bin/bash -c \
  "php /var/www/nextcloud/occ files_external:verify <mount-id>" www-data
```

Mount IDs: `4` = first user, `5` = second user

### C — Nextcloud cache shows deleted/consumed documents

The hourly cronjob resolves this automatically. To trigger immediately:

```bash
pct exec 210 -- /usr/local/sbin/scan-paperless-inbox.sh
```

Check result:
```bash
pct exec 210 -- tail -20 /var/log/nextcloud-paperless-scan.log
```

### D — SMB mount not active on Proxmox host

```bash
# Trigger automount manually
ls /mnt/smb/paperless

# Verify
findmnt -t cifs | grep paperless
```

---

## Failure Modes

| Symptom | Likely Cause | Action |
|---|---|---|
| Nextcloud shows red icon on Paperless Inbox | Consumption dir deleted or SMB down | Recovery A or D |
| Document uploaded but not appearing in Paperless | Consumer polling delay (up to 30s) or dir missing | Wait 30s; check Recovery A |
| Document appears in Nextcloud cache after consumption | Cache not yet synced | Recovery C |
| `files_external:verify` returns error | SMB share unreachable or credentials wrong | Check VM102 Samba, verify SMB user `paperless-ingest` |
| Paperless consumer logs show permission errors | UID/GID mismatch on consumption dir | Check `force user`/`force group` in VM102 smb.conf |

---

## Notes

- Consumption dirs may not exist after a full import cycle — this is normal behavior.
- Adding a new user requires: new SMB share on VM102, new External Storage mount in Nextcloud,
  new Paperless workflow. The cache sync cronjob picks up new users automatically.
- See: [Paperless-ngx Service Documentation](../../docs/services/paperless.md) — Nextcloud Integration section
- See: [Nextcloud Service Documentation](../../docs/services/nextcloud.md)
