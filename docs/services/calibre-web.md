# Calibre-Web (LXC220)

Calibre-Web is deployed via Docker Compose inside an unprivileged Debian LXC container.

## Deployment

- Image: `lscr.io/linuxserver/calibre-web:latest`
- Compose path (runtime): `/srv/calibreweb/docker-compose.yml`
- Persistent config: `/srv/calibreweb/config` mounted to `/config`

## Data / Storage Integration

- Library mount (web UI): `/books` (CIFS-mounted storage from the dedicated storage VM)
- Mount mode: read-only (`/books:/books:ro`) to enforce least-privilege for the web service
- Import mount (auto-import job only): `/books-rw` — a separate **read-write** mount of the same Books share, used exclusively by the host-side import job (see [Auto-Import](#auto-import)), never by the container

Important:
- The Calibre-Web **container** sees the library read-only and never modifies library files.
- The only writer to the library is the systemd-timed import job on the LXC host (not the container).
- No database or stateful workload is written by the container on CIFS.

## Auto-Import

Ebooks dropped into `/books-rw/_import` (over SMB) are imported into the library automatically.

- **Mechanism:** Ansible role `calibre-importer` deploys `/usr/local/bin/calibre-import.sh` and a `calibre-import.timer` that polls every 2 minutes (polling, not inotify — inotify does not observe writes made by the SMB server).
- **CIFS / SQLite-locking constraint:** `metadata.db` lives on CIFS. Calibre opens it with `BEGIN EXCLUSIVE TRANSACTION` (a POSIX byte-range lock the SMB client does not translate reliably), so `calibredb add` straight onto the CIFS copy fails with `apsw.BusyError: database is locked` — even with the container stopped. Verified: the identical add against a **local** copy of `metadata.db` succeeds. The CIFS mount carries no `nobrl` option, which would otherwise suppress the byte-range locks.
- **Workaround the script uses:** stop `calibre-web` (consistent DB snapshot, no concurrent writer) → copy `metadata.db` to a local working library under `/tmp` → `calibredb add` there → `tar` the new book directories back onto the CIFS library (plain copy, no byte-range locks) → atomically swap the updated `metadata.db` in → restart `calibre-web` (guaranteed via an EXIT trap).
- **On success** the source file is deleted (the MergerFS pool is near full — no second copy is kept); **on failure** it is quarantined under `/books-rw/_import/.failed`.

## Security / Exposure

- Loopback-only binding: `127.0.0.1:8083 -> container:8083`
- No LAN exposure.
- No public ingress / no router port forwarding.
- Remote access is provided exclusively via Tailscale (identity-based overlay).

## Identity / Permissions

- Container process UID/GID configured via:
  - `PUID=1000`
  - `PGID=1000`
- Library is mounted read-only via CIFS.
- No stateful or write-heavy workload is stored on network mounts.
- Ownership consistency is preserved across unprivileged LXC + CIFS boundaries.

## Access Model (Zero Trust)

- Service acts as a **read-only consumer node** in the platform.
- No service-to-service provider role.
- Network segmentation is enforced via Tailscale ACL (node tags + policy rules).
- See: [docs/platform/tailscale-acl.md](../platform/tailscale-acl.md)

## Failure Impact

If the CIFS mount (`/books`) becomes unavailable:

- Calibre-Web may start but show an empty or inaccessible library.
- No data loss occurs due to read-only mount configuration.
- Monitoring should detect mount degradation.

## Related Documents

- [LXC220 Node](../nodes/lxc220.md)
- [Storage Design](../platform/storage-design.md)
- [Tailscale ACL](../platform/tailscale-acl.md)
