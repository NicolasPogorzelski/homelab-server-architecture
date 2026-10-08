# Jellyfin (VM100)

Jellyfin is deployed via Docker Compose on VM100 with NVIDIA GPU hardware transcoding.

## Deployment

- Image: `jellyfin/jellyfin:10.11.11`
- Compose path (runtime): `/opt/docker/jellyfin/docker-compose.yml`
- GPU acceleration: enabled (`gpus: all`, NVIDIA runtime)
- Runs as non-root user (`user: 1000:1000`)

## Storage Integration

Media is read-only mounted from VM102 via systemd automount (SMB/autofs):

- `${JF_MEDIA_FILME}` -> `/media/Filme:ro`
- `${JF_MEDIA_SERIEN}` -> `/media/Serien:ro`

Config, cache, and metadata use local persistent volumes on VM100.

## Access Model (Zero Trust)

- No public ingress / no router port forwarding.
- Jellyfin publishes on vm100's Tailscale address only (`<tailscale-ip-vm100>:8096`, set as
  `JELLYFIN_BIND_ADDR` in the node's `.env`). Nothing on the LAN reaches it; clients use
  `http://gpu-vm.<tailnet-id>.ts.net:8096` or the Tailscale IP (WireGuard-encrypted, no TLS
  hostname).
- From 2026-10-01 to 2026-10-07 it sat on loopback behind `tailscale serve --tcp 8096`. That
  forwarder stalled streams to the streaming box, and Jellyfin moved to the direct bind
  ([KE-28](../platform/known-errors.md#ke-28)).
- At boot, `docker.service` waits for the Tailscale address through `tailscale_boot_gate`, with
  `docker_boot_retry` behind it ([KE-18](../platform/known-errors.md#ke-18)).
- Network policy enforced via Tailscale ACL (node tags + ACL JSON).
- See: [docs/platform/tailscale-acl.md](../platform/tailscale-acl.md)
- See: [Loopback + Tailscale Serve ADR](../decisions/loopback-tailscale-serve.md)

| Source | Port | Access |
|---|---|---|
| `tag:admin`, `tag:admin-mobile`, `tag:client`, `tag:untrusted` | 8096 | Allowed |
| One external user through machine sharing | 8096 | Allowed |
| `tag:monitoring` | 8096 | Allowed (blackbox probe) |
| `tag:reader`, `tag:tier0`, every other tag | 8096 | Denied |

## Subtitle Extraction

When a client asks for an embedded subtitle as a separate stream, Jellyfin runs ffmpeg over the
whole file and extracts every subtitle track at once, into `/config/data/subtitles/`. On a 4K remux
that means reading tens of gigabytes over CIFS before the first frame: measured 2026-10-07, a 46 GB
film ran at about 110 MB/s for five minutes, and the client gave up long before. The server option
`EnableSubtitleExtraction` in `encoding.xml` is already `false` and does not stop it.

- The lever is the subtitle mode. "Default" plays any track the file flags as default, and many
  4K episodes carry a German forced track flagged that way; "Only forced" selects the same track.
  Every profile is held at "None" by the `jellyfin_user_prefs` role. Moonfin has a subtitle
  setting of its own, which belongs at "None" too and is not something the server can see.
- An extraction keeps running after the client closes, and it saturates the read path for every
  other stream until it ends.
- Extracted tracks are cached, so a second start of the same file is immediate.
- Anything else that reads the archive has the same effect. Diagnose from `/opt/docker/jellyfin/.env`,
  `docker inspect` and `ffprobe`, never with a recursive search under `/srv` or by decoding a file
  while it is being watched.

## CUDA Watchdog

Jellyfin intermittently loses CUDA access at runtime (see [KE-10](../platform/known-errors.md#ke-10)).
A watchdog script checks GPU availability every 30 minutes and restarts the container if access is lost.

### Deploy on VM100

Managed by the `jellyfin_watchdog` Ansible role - script, service unit and timer:

```bash
ansible-playbook playbooks/jellyfin-watchdog.yml --check --diff   # preview
ansible-playbook playbooks/jellyfin-watchdog.yml                  # apply
```

### Schedule

`jellyfin-cuda-watchdog.timer` - a monotonic timer, not a calendar one:

```
OnBootSec=5min
OnUnitActiveSec=30min
```

The first poll waits 5 minutes after boot so Docker and the NVIDIA runtime have
settled; restarting a half-started container is worse than checking it late.
`Persistent=` is deliberately absent - it applies only to `OnCalendar=` timers, and
a poll missed while the host was powered off has nothing to catch up on.

The role removed the previous `*/30 * * * *` root crontab entry. Do not re-add it.

### Verify

```bash
systemctl list-timers jellyfin-cuda-watchdog.timer
journalctl -t jellyfin-cuda-watchdog -n 20
```

Because the watchdog is a systemd unit, a failing run now raises the fleet-wide
`SystemdUnitFailed` alert. As a cron job it failed silently.

### Script reference

[snippets/scripts/jellyfin-cuda-watchdog.sh](../../snippets/scripts/jellyfin-cuda-watchdog.sh)

---

## Moonfin Direct Play

Moonfin's built-in player on the Android TV box stops a small set of 4K remuxes three to five
seconds after the start, with German audio only. Measured 2026-10-07 on one episode:

| Player | German audio | English audio |
|---|---|---|
| Moonfin built-in, direct play | stops at 3-5 s, every start | plays |
| External player (JustPlayer) | plays to the end, subtitles switchable | not tried |
| Jellyfin Web, transcoded without subtitle streams | plays | not tried |

- While the player stands still, the server sends nothing, reads nothing from vm102 and runs no
  ffmpeg, and the session reports the subtitle index as none. The stop is inside the client.
- Ruled out by measurement: the German audio track (codec, bitrate, 2.002 s start offset and packet
  timing identical to an episode that plays), interleaving (audio within about 3 MB of its video in
  both), storage and network load.
- What the stopping files share: ten subtitle tracks including text (SRT) tracks, with the German
  text track flagged default and the German tracks flagged forced. Files with four image-only
  tracks and no forced flag play in German.
- Not yet established: which property the player reacts to. Clearing the flags in the file and
  retrying proved nothing, because the server was not made to re-read the file and still
  described the tracks as forced to the client. The test that decides it is to clear the flags,
  refresh the item's metadata, and start again in German.
- An external player is not the fix: the built-in player is what carries playback sync and
  trickplay previews.

## Failure Impact

If VM100 becomes unavailable:

- No media streaming.
- No data loss - media is read-only from VM102 storage.
- Recovery: restart VM100, verify SMB automounts, confirm Docker containers are running.

## Related Documents

- [VM100 Node](../nodes/vm100.md)
- [Storage Design](../platform/storage-design.md)
- [Tailscale ACL](../platform/tailscale-acl.md)
