# Jellyfin

Media server on vm100 with NVIDIA hardware transcoding. Node details: [vm100](../nodes/vm100.md).

## Deployment

- Compose stack in `/opt/docker/jellyfin`, source `docker/jellyfin/docker-compose.yml`; the image
  version is pinned there, synced by `docker_compose_update`
- GPU reserved through the NVIDIA runtime; runs as `${PUID}:${PGID}`, not root
- Config and metadata on `/mnt/vm-data/jellyfin`, the `jellyfin-data` disk; the cache on
  `/mnt/scratch/jellyfin-cache` ([scratch pool](../decisions/scratch-pool-on-former-boot-ssd.md))

## Storage Integration

Libraries are mounted read-only from vm102 through systemd automounts over SMB:

- `${JF_MEDIA_FILME}` -> `/media/Filme:ro` (share `media-jf-filme`)
- `${JF_MEDIA_SERIEN}` -> `/media/Serien:ro` (share `media-jf-serien`)

## Access Model

- Jellyfin publishes on vm100's Tailscale address only, `<tailscale-ip-vm100>:8096`
  (`JELLYFIN_BIND_ADDR` in the node's `.env`; `docker_compose_update` refuses an `.env` without it).
  The `tailscale serve` forwarder stalled streams and is not used
  ([KE-28](../platform/known-errors.md#ke-28)).
- At boot `docker.service` waits for that address through `tailscale_boot_gate`, with
  `docker_boot_retry` behind it ([KE-18](../platform/known-errors.md#ke-18)).
- Clients use `http://gpu-vm.<tailnet-id>.ts.net:8096`; the transport is WireGuard, with no TLS
  hostname. No LAN or public path ([media over the tailnet](../decisions/media-over-the-tailnet.md)).

| Source | Port 8096 |
|---|---|
| `tag:admin`, `tag:admin-mobile`, `tag:client`, `tag:untrusted`, `tag:media-player` | allowed |
| one external user through machine sharing | allowed |
| `tag:monitoring` | allowed (blackbox probe) |
| `tag:reader`, `tag:tier0`, every other tag | denied |

Rules: [tailscale-acl.md](../platform/tailscale-acl.md).

## Subtitle Extraction

When a client asks for an embedded subtitle as a separate stream, Jellyfin runs ffmpeg over the
whole file and extracts every subtitle track into `/config/data/subtitles/`. On a 4K remux that
reads tens of gigabytes over CIFS before the first frame.
Verified 2026-10-07: a 46 GB file read at about 110 MB/s for five minutes; the client gave up first.

- `EnableSubtitleExtraction=false` in `encoding.xml` does not stop it. The lever is the user's
  subtitle mode: "Default" and "Only forced" both pick forced tracks flagged as default. The
  `jellyfin_user_prefs` role holds every profile at "None".
- Clients in direct play that read embedded text tracks themselves start no extraction.
  Verified 2026-10-08 over eight starts: no ffmpeg, nothing written to `/config/data/subtitles/`.
- An extraction keeps running after the client closes and saturates the read path for every other
  stream. Extracted tracks are cached.
- Anything else that reads the archive has the same effect. Diagnose from the `.env`,
  `docker inspect` and `ffprobe`, never with a recursive search under `/srv`.

## CUDA Watchdog

Jellyfin intermittently loses CUDA access ([KE-10](../platform/known-errors.md#ke-10)). A restart
ends every stream, direct play included, so with CUDA gone the watchdog asks Jellyfin's `/Sessions`
who is playing:

| Sessions playing | Action |
|---|---|
| none | restart |
| at least one video transcode (`TranscodingInfo.IsVideoDirect` false) | restart |
| only direct play or direct stream | hold, check again next minute |
| API does not answer | restart |

- Role `jellyfin_watchdog`: `snippets/scripts/jellyfin-cuda-watchdog.sh`, its service and a
  monotonic timer (`OnBootSec=5min`, `OnUnitActiveSec=1min`, `AccuracySec=5s`, no `Persistent=`).
- The API key sits in a root-only header file read by `curl -H @file`, never on a command line.
- Metrics: `jellyfin_cuda_ok`, `jellyfin_watchdog_restart_held`,
  `jellyfin_watchdog_last_restart_timestamp_seconds`. `JellyfinCudaLost` fires after ten minutes of
  `jellyfin_cuda_ok == 0`. A failed run raises `SystemdUnitFailed`.

```bash
ansible-playbook playbooks/jellyfin-watchdog.yml --check --diff
systemctl list-timers jellyfin-cuda-watchdog.timer
journalctl -t jellyfin-cuda-watchdog -n 20
```

## Moonfin Direct Play

Playback hangs on the streaming box are a client fault, not a platform one, and are tracked
upstream as [Moonfin-Core#1775](https://github.com/Moonfin-Client/Moonfin-Core/issues/1775).

## Failure Impact

- vm100 down: no media streaming; libraries on vm102 are unaffected.
- `jellyfin-data` is not in the guest backup. `app_backup` writes Jellyfin's own archive (database
  and subtitles) daily onto that disk, seven kept, and `backup_mirror` copies the newest to the
  Backup-Archive monthly; metadata images and trickplay are rebuilt from the media
  ([KE-13](../platform/known-errors.md#ke-13), [backup flow](../architecture/backup-flow.md)).
- Recovery: restart vm100, check the automounts, `docker compose ps` in the stack directory.

## Related Documents

- [vm100](../nodes/vm100.md)
- [Storage design](../platform/storage-design.md)
