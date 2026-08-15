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
- Jellyfin binds to `0.0.0.0:8096` for LAN streaming performance (documented trade-off).
- Remote access is via Tailscale IP directly (WireGuard-encrypted, no TLS hostname).
- LAN exposure is intentional and limited to port 8096 only.
- Network policy enforced via Tailscale ACL (node tags + ACL JSON).
- See: [docs/platform/tailscale-acl.md](../platform/tailscale-acl.md)
- See: [Loopback + Tailscale Serve ADR](../decisions/loopback-tailscale-serve.md) - section "Documented Exceptions"

| Source | Port | Access |
|---|---|---|
| `tag:client` | 8096 | Allowed |
| `tag:untrusted` | 8096 | Allowed |
| `tag:admin`, `tag:tier0` | all | Allowed |

## CUDA Watchdog

Jellyfin intermittently loses CUDA access at runtime (see [KE-10](../platform/known-errors.md#ke-10-jellyfin-loses-cuda-access-intermittently--container-restart-required)).
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
