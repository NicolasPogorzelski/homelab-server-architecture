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

- The lever is the client: subtitle mode "None" in the user profile and in Moonfin. "Only forced"
  is not enough, because the 4K files carry a German track flagged as forced.
- An extraction keeps running after the client closes, and it saturates the read path for every
  other stream until it ends.
- Extracted tracks are cached, so a second start of the same file is immediate.

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

## Failure Impact

If VM100 becomes unavailable:

- No media streaming.
- No data loss - media is read-only from VM102 storage.
- Recovery: restart VM100, verify SMB automounts, confirm Docker containers are running.

## Related Documents

- [VM100 Node](../nodes/vm100.md)
- [Storage Design](../platform/storage-design.md)
- [Tailscale ACL](../platform/tailscale-acl.md)
