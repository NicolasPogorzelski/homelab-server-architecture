# VM100 Services (GPU / Media)

This document describes the current containerized media services running on VM100 (Compute/GPU VM).

## Jellyfin

- Deployment: Docker Compose (`/opt/docker/jellyfin/docker-compose.yml` on VM100)
- GPU acceleration: enabled (`gpus: all` + NVIDIA environment variables)
- Runs as non-root user (`user: 1000:1000`)
- Persistent application data:
  - `/mnt/vm-data/jellyfin/config` -> `/config`
  - `/mnt/vm-data/jellyfin/cache` -> `/cache`
  - `/mnt/vm-data/jellyfin/metadata` -> `/metadata`
- Media mounts (read-only, least privilege):
  - `/media/jellyfin/Filme` -> `/media/Filme:ro`
  - `/media/jellyfin/Serien` -> `/media/Serien:ro`
- Port exposure: `8096/TCP` (LAN)

## Audiobookshelf

- Deployment: Docker Compose (`/opt/docker/audiobookshelf/docker-compose.yml` on VM100)
- Media mounts (read-only, least privilege):
  - `/media/audiobookshelf/Audiobooks` -> `/audiobooks:ro`
  - `/media/audiobookshelf/Podcasts` -> `/podcasts:ro`
- Port exposure: `13378/TCP` (LAN)

## Storage Mount Strategy (Reboot-Safe)

Media paths on VM100 are provided via systemd automount units to ensure reboot-safe startup behavior:
- `/media/jellyfin` (autofs)
- `/media/audiobookshelf` (autofs)

Note: A legacy `media-mergerfs.mount` unit exists on VM100 but is not used for service mounts in the current state.

## Security / Exposure Notes (Trade-off)

- No public reverse proxy and no router port-forwarding.
- Remote access follows the zero-trust overlay model (Tailscale).
- Jellyfin/Audiobookshelf are intentionally reachable in the local network to optimize in-home streaming performance (bandwidth/latency) and avoid unnecessary transcoding.
