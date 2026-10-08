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
  Every profile is held at "None" by the `jellyfin_user_prefs` role.
- Moonfin in direct play reads embedded text tracks from the container itself and never asks the
  server for them. Measured 2026-10-08 over eight starts that showed an embedded text track
  (`subtitle track N picked by positional`, `0 external files`): Jellyfin started no ffmpeg and
  wrote nothing to `/config/data/subtitles/`. Moonfin's own subtitle setting can stay on.
- An extraction keeps running after the client closes, and it saturates the read path for every
  other stream until it ends.
- Extracted tracks are cached, so a second start of the same file is immediate.
- Anything else that reads the archive has the same effect. Diagnose from `/opt/docker/jellyfin/.env`,
  `docker inspect` and `ffprobe`, never with a recursive search under `/srv` or by decoding a file
  while it is being watched.

## CUDA Watchdog

Jellyfin intermittently loses CUDA access at runtime (see [KE-10](../platform/known-errors.md#ke-10)).
A watchdog script checks GPU availability every 30 minutes and restarts the container if access is lost.

The restart ends every running stream, including direct play that never touches the GPU. The
script does not look for active sessions. On 2026-10-08 it found CUDA lost at 11:29:08, Docker
killed the container after its 10 s stop timeout, and a direct-play stream to the box stopped.

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

Moonfin's built-in player on the Android TV box hangs on most starts in which the display switches
refresh rate while the audio is bitstreamed to the AV receiver. The fault is in the client and is
reported upstream as [Moonfin-Core#1775](https://github.com/Moonfin-Client/Moonfin-Core/issues/1775).
Measured 2026-10-08 with `adb logcat` on the box and Moonfin's own diagnostic reports, which the
app uploads to Jellyfin's log directory:

| Box UI mode | Audio in Moonfin | Starts | Playing after 30 s |
|---|---|---|---|
| 3840x2160 @ 59.94 Hz, so every start switches | passthrough (AC3, E-AC3) | 7 | 2 |
| 3840x2160 @ 23.976 Hz, no switch | passthrough | 4 | 4 |
| 3840x2160 @ 59.94 Hz, so every start switches | passthrough disabled, PCM | 6 | 6 |

- Every start with a switch runs the same sequence. Moonfin requests the 23.976 Hz mode once the
  video decoder is up and opens the audio track about 30 ms later; the HDMI link renegotiates 0.9
  to 1.5 s after that and kills the passthrough track (`AudioTrack write failed: -6`). Moonfin
  rebuilds it. In the hanging starts the rebuilt track reported timestamp jumps of 208 ms, the
  player dropped frames and stayed in `buffering` with more than 11 s buffered until its own
  watchdog failed playback after 31 s.
- Ruled out across three titles: server, storage and network (direct play, no ffmpeg, vm102 load
  below 0.2), the file (AC3 and E-AC3, Dolby Vision P7 and P8, HDR10), subtitles (hangs with the
  track on and off) and Moonfin's scaling option (Scale on TV picks the same mode). The
  2026-10-07 version of this section blamed the forced subtitle tracks; it rested on a handful of
  starts of a fault whose outcome varies from one start to the next.
- Moonfin 2.6.0 has no setting that orders the switch before the audio. Its "Video start delay"
  slider is stored and synced but read by no playback code, and the box's own "Match frame rate"
  entry is a one-off action, not a mode.
- **Interim:** audio passthrough in Moonfin is set to Disabled. Moonfin decodes with its bundled
  FFmpeg and sends multichannel PCM, and the PCM path survives the renegotiation. Refresh rate
  switching, Dolby Vision and subtitles stay on. Cost: object audio (Atmos, DTS:X) is reduced to
  its channel bed, and dynamic range control moves from the receiver to the decoder.
- **Revert when:** a Moonfin release closes #1775. Set passthrough back to Auto and start a
  23.976 fps title with AC3 audio from a 59.94 Hz UI at least three times; one clean start proves
  nothing for a fault that let two of seven through.
- An external player is not the fix: the built-in player is what carries playback sync and
  trickplay previews. While an external player runs, Moonfin also reports the time since the
  hand-off as the playback position, so the server holds a wrong resume point until it returns.

## Failure Impact

If VM100 becomes unavailable:

- No media streaming.
- No data loss - media is read-only from VM102 storage.
- Recovery: restart VM100, verify SMB automounts, confirm Docker containers are running.

## Related Documents

- [VM100 Node](../nodes/vm100.md)
- [Storage Design](../platform/storage-design.md)
- [Tailscale ACL](../platform/tailscale-acl.md)
