# Paperless-ngx

Document management with OCR, classification and full-text search, on lxc211. Paperless-ngx runs
v3; the pinned images are in `docker/paperless/docker-compose.yml`. Node details:
[lxc211](../nodes/lxc211.md).

## Deployment

- Compose stack in `/opt/paperless`, synced from the repository by `docker_compose_update`
- `.env` rendered by the `paperless_env` role from vaulted secrets (mode 600, never committed)
- Containers on a Docker bridge network, addressed by container name:

| Container | Role |
|---|---|
| `paperless` | web UI, API, Celery workers |
| `paperless-redis` | task queue, cache, locking |
| `paperless-gotenberg` | Office to PDF conversion |
| `paperless-tika` | text and metadata extraction |

## Storage

| Data | Location |
|---|---|
| Database | `paperless_db` on lxc260, TLS over the tailnet ([PostgreSQL platform](./postgresql-platform.md)) |
| Originals, archive, thumbnails, consumption, export | `/data/paperless` on the vm102 `[Paperless]` share (`mp0`) |
| Application data | Docker volume `paperless-data` |
| Logs, Docker engine state | `/var/lib/paperless` on the aux-disk (`mp1`) |

No database files on CIFS.

## Access Model

- Paperless binds `127.0.0.1:8000` and is published through `tailscale serve` on 443:
  `https://paperless.<tailnet-id>.ts.net` ([decision](../decisions/loopback-tailscale-serve.md)).
- No LAN or public path; `lan_guard` drops new inbound LAN connections on lxc211.
- `PAPERLESS_URL` and `PAPERLESS_CSRF_TRUSTED_ORIGINS` are both set to that URL; without the second,
  browser and mobile POST requests fail with 403.
- Clients: browsers and the Paperless Mobile app, both through the tailnet. Grants are in
  [tailscale-acl.md](../platform/tailscale-acl.md).

## Nextcloud Ingestion

1. A user uploads into the Nextcloud External Storage folder "Paperless Inbox".
2. Nextcloud writes over the tailnet to `[Paperless-ingest-user1]` or `[Paperless-ingest-user2]` on
   vm102, user `paperless-ingest`, which land in `consumption/user1/` or `consumption/user2/`.
3. The consumer polls every 30 s (`PAPERLESS_CONSUMER_POLLING_INTERVAL=30`) and scans
   subdirectories (`PAPERLESS_CONSUMER_RECURSIVE=true`). inotify does not see writes on CIFS.
4. A workflow per user matches the path (`*user1*`, `*user2*`) and assigns the owner.
5. Paperless deletes the consumed file, and removes a subdirectory it has emptied.

On lxc210, `paperless-inbox-scan.timer` (role `paperless_inbox_scan`) runs `occ files:scan` hourly
so the Nextcloud file cache drops consumed files.

Missing consumption subdirectories and stale External Storage mounts are repaired with the
[ingestion runbook](../../runbooks/integration/nextcloud-paperless.md). Share setup:
[Nextcloud](./nextcloud.md#external-storage-paperless-integration), [Samba](../platform/samba.md).

## Version 3 Settings

Two v3 renames fail silently here, and `paperless_env` renders both:

- `PAPERLESS_CONSUMER_POLLING` became `PAPERLESS_CONSUMER_POLLING_INTERVAL`. Without it the
  consumer falls back to inotify and never sees the CIFS inbox.
- `PAPERLESS_DBSSLMODE` became `PAPERLESS_DB_OPTIONS=sslmode=require`.

Upstream defaults kept: duplicates are accepted and flagged; an archive version is produced only for
documents without a text layer (`PAPERLESS_ARCHIVE_FILE_GENERATION=auto`); the search index is
Tantivy. A future image change applies `paperless_env` first, because its handler recreates the
container.

## Failure Impact

- No ingestion, search or document access. Uploads wait in the consumption share.
- Documents on vm102 and metadata on lxc260 are unaffected.
- With lxc260 down, Paperless does not start; restore lxc260 first.
- Bulk imports of thousands of documents can exhaust lxc211's memory; raise its cores and RAM for
  the import.

## Related Documents

- [lxc211](../nodes/lxc211.md)
- [PostgreSQL platform](./postgresql-platform.md)
- [Nextcloud](./nextcloud.md)
