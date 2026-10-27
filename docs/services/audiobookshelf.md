# Audiobookshelf

Audiobook and podcast server on vm100. Node details: [vm100](../nodes/vm100.md).

## Deployment

- Compose stack in `/opt/docker/audiobookshelf`, source `docker/audiobookshelf/docker-compose.yml`
  (image version there), synced by `docker_compose_update`
- Config and metadata under `${ABS_DATA_ROOT}` on vm100's root disk, which the guest backup covers
- Audiobookshelf's own daily archive goes to `${ABS_BACKUP_ROOT}` (`/backups` in the container) on
  the data disk; `backup_mirror` copies the newest to the Backup-Archive monthly
  ([backup flow](../architecture/backup-flow.md))

## Storage Integration

Libraries are mounted read-only from vm102 through systemd automounts over SMB:

- `${ABS_AUDIOBOOKS_ROOT}` -> `/audiobooks:ro` (share `media-abs-audiobooks`)
- `${ABS_PODCASTS_ROOT}` -> `/podcasts:ro` (share `media-abs-podcasts`)

## Access Model

- Published on `127.0.0.1:13378` only. The tailnet reaches it through
  `tailscale serve --bg --tcp 13378 tcp://127.0.0.1:13378` on vm100
  ([decision](../decisions/loopback-tailscale-serve.md)).
- Clients use `http://gpu-vm.<tailnet-id>.ts.net:13378` or vm100's Tailscale address; the transport
  is WireGuard, with no TLS hostname. No LAN or public path
  ([media over the tailnet](../decisions/media-over-the-tailnet.md)).
- Clients appear to Audiobookshelf as `127.0.0.1`, because `tailscale serve` forwards the TCP stream.

| Source | Port 13378 |
|---|---|
| `tag:admin`, `tag:admin-mobile`, `tag:client`, `tag:reader` | allowed |
| one external user through machine sharing | allowed |
| `tag:monitoring` | allowed (blackbox probe) |
| `tag:untrusted`, `tag:media-player`, every other tag | denied |

Rules: [tailscale-acl.md](../platform/tailscale-acl.md).

## Failure Impact

- vm100 down: no audiobook or podcast streaming; the libraries on vm102 are unaffected.
- vm102 unreachable at boot: the container start fails and `docker_boot_retry` retries it
  ([KE-27](../platform/known-errors.md#ke-27)).
- Recovery: restart vm100, check the automounts, `docker compose ps` in the stack directory.

## Related Documents

- [vm100](../nodes/vm100.md)
- [Storage design](../platform/storage-design.md)
