# Calibre-Web

Web front end for the e-book library on lxc220, with a timer that imports new books into the
library. Node details: [lxc220](../nodes/lxc220.md).

## Deployment

- Compose stack in `/srv/calibreweb`, source `docker/calibre-web/docker-compose.yml`; the image is
  pinned there, synced by `docker_compose_update`
- Config in `/config` (bind mount), container user from `PUID`/`PGID` in the node's `.env`
- Published on `127.0.0.1:8083`

## Storage

| Data | Mount | Mode |
|---|---|---|
| Library for the web UI | `mp0: /mnt/smb/books -> /books`, bound into the container as `/books:ro` | read-only |
| Local state | `mp1: /mnt/aux-disk/calibreweb -> /var/lib/calibreweb` | read-write |
| Library for the import job | `mp2: /mnt/smb/books-rw -> /books-rw`, never seen by the container | read-write |

The container never writes the library. The only writer is the import job on the node.

## Auto-Import

Books dropped into `/books-rw/_import` over SMB are added to the library.

- Role `calibre_importer` installs `calibre`, `/usr/local/bin/calibre-import.sh` and
  `calibre-import.timer`, which polls every 2 minutes; inotify does not see writes made by the SMB
  server.
- `metadata.db` lives on CIFS, and `calibredb add` on it fails with `apsw.BusyError: database is
  locked`, because Calibre's exclusive transaction takes byte-range locks the SMB client does not
  translate. The same add against a local copy succeeds.
- The script therefore stops `calibre-web`, copies `metadata.db` to a local working library under
  `/tmp`, adds the books there, copies the new book directories back with `tar`, swaps the updated
  `metadata.db` in atomically, and starts `calibre-web` again from an EXIT trap.
- Success deletes the source file; failure moves it to `/books-rw/_import/.failed`.
- The script exits 1 unless `/books-rw` is a CIFS mount, so a missing mount raises
  `SystemdUnitFailed` ([KE-15](../platform/known-errors.md#ke-15)).

Decision and alternatives: [Calibre CIFS SQLite import](../decisions/calibre-cifs-sqlite-import.md).

## Access Model

- Calibre-Web binds loopback and is published through `tailscale serve` on 443:
  `https://calibreweb.<tailnet-id>.ts.net` ([decision](../decisions/loopback-tailscale-serve.md)).
- No LAN or public path; `lan_guard` drops new inbound LAN connections on lxc220.
- Grants: the admin workstations, the client notebook, the e-book reader and the monitoring probe
  ([tailscale-acl.md](../platform/tailscale-acl.md)). The service reaches nothing on the tailnet
  itself.

## Failure Impact

- `/books` missing: Calibre-Web starts with an empty or unreadable library; no data loss, the mount
  is read-only.
- lxc220 down: no web access; dropped files wait in `_import`.

## Related Documents

- [lxc220](../nodes/lxc220.md)
- [Storage design](../platform/storage-design.md)
