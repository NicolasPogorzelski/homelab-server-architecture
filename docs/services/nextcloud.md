# Nextcloud

File sync, sharing and Talk on lxc210, as a native Debian stack. User data is on vm102. Node
details: [lxc210](../nodes/lxc210.md).

## Components

- Apache 2.4 with PHP 8.2 (Debian packages); application in `/var/www/nextcloud`, owned by
  `www-data` ([KE-25](../platform/known-errors.md#ke-25))
- MariaDB in the container (`dbhost=localhost`, database `nextcloud`), not on the PostgreSQL
  platform: Nextcloud predates lxc260 and upstream recommends MariaDB. No migration is planned.
- Redis on `127.0.0.1:6379` for file locking, APCu as local cache
- Collabora Online for document editing (below)
- Nextcloud 34, the last major that runs on PHP 8.2

## Storage

- User data: `/mnt/nextcloud`, the vm102 `[Nextcloud]` share mounted by the host and bind-mounted
  into the container, owned by `www-data` through the mount's UID mapping
- MariaDB data on the container's root disk; nightly verified dumps go to the `[DB-Backups]` share
- No database on CIFS; Redis handles locking.

## Collabora Online

The `richdocumentscode` app extracts a Collabora (CODE) AppImage into `/tmp` and runs it as
`www-data`. There is no package and no unit, so no role can own it without owning the app.

- It listens on `*:9983` and accepts no listen address. Nextcloud reaches it through `proxy.php` on
  its own web server, over loopback. `nft_guard` drops 9983 on every interface except loopback, and
  `listener_metrics` lists it as a recorded exception.
- Its process sandbox (capabilities and seccomp) is switched off by the AppImage, because it does
  not work in an unprivileged LXC; uploaded documents are confined by the container boundary.
- vm102's `snapraid.conf` excludes `/Nextcloud/appdata_*/richdocuments/remoteData/`.
- The `onlyoffice` app is disabled; editing runs through `richdocuments` alone.

## Access Model

- Reached over the tailnet only, at `https://nextcloud.<tailnet-id>.ts.net`. Apache terminates TLS
  with the certificate from `tailscale cert`, renewed by the `tailscale_cert` role
  ([KE-16](../platform/known-errors.md#ke-16)).
- No LAN access: `lan_guard` drops new inbound LAN connections, including to Apache's wildcard bind
  ([media over the tailnet](../decisions/media-over-the-tailnet.md)).
- No public reverse proxy, no port forwarding.
- Grants: admin workstations, admin phone, client devices, one external user through machine
  sharing, the monitoring probe ([tailscale-acl.md](../platform/tailscale-acl.md)).
- Apache binds `*:80` and `*:443` instead of the Tailscale address; tracked in the
  [remediation plan](../platform/remediation-plan.md#open-items).

## External Storage (Paperless Integration)

The `files_external` app gives two users an upload path into Paperless-ngx:

| Mount ID | Nextcloud user | SMB share | Target on vm102 |
|---|---|---|---|
| 4 | user1 | `Paperless-ingest-user1` | `/mnt/mergerfs/Paperless/consumption/user1` |
| 5 | user2 | `Paperless-ingest-user2` | `/mnt/mergerfs/Paperless/consumption/user2` |

- Host: `storage.<tailnet-id>.ts.net`, the full MagicDNS name, over the tailnet. The short name
  `storage` also resolves on the LAN, where `smb_guard` refuses lxc210
  ([KE-29](../platform/known-errors.md#ke-29)). The path needs the
  `nextcloud` grant to `tag:storage:445` in [tailscale-acl.md](../platform/tailscale-acl.md).
- SMB user `paperless-ingest`; login and password are stored on each mount
  (`password::password`).
- Paperless consumes and deletes uploaded files within about 30 s.
- `paperless-inbox-scan.timer` (role `paperless_inbox_scan`) runs `occ files:scan` on each user's
  "Paperless Inbox" hourly, so the file cache drops consumed files. The same run writes
  `paperless_ingest_storage_up` per mount from `occ files_external:verify`;
  `PaperlessIngestStorageDown` fires after two hours of failure.

Repair procedures: [ingestion runbook](../../runbooks/integration/nextcloud-paperless.md).

## Failure Impact

- lxc210 down: no sync, no Talk, no upload path into Paperless. Data on vm102 is unaffected.
- CIFS mount missing: Nextcloud starts but cannot read user data.
- MariaDB lost: restore from the dump ([MariaDB restore](../../runbooks/database/mariadb-restore.md)).

## Related Documents

- [lxc210](../nodes/lxc210.md)
- [Paperless-ngx](./paperless.md)
- [Storage design](../platform/storage-design.md)
