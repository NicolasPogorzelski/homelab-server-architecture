# VM100 Services

This document describes the current containerized services running on VM100 (Compute/GPU).

## Jellyfin

- Deployment: Docker Compose
- GPU acceleration: enabled (`gpus: all`, NVIDIA runtime variables)
- Runs as non-root user (UID/GID 1000:1000)
- Media mounts: read-only
  - /media/jellyfin/Filme -> /media/Filme:ro
  - /media/jellyfin/Serien -> /media/Serien:ro
- Port exposure: 8096/TCP (LAN use)

## Audiobookshelf

- Deployment: Docker Compose
- Media mounts: read-only
  - /media/audiobookshelf/Audiobooks -> /audiobooks:ro
  - /media/audiobookshelf/Podcasts -> /podcasts:ro
- Port exposure: 13378/TCP (LAN use)

## Security / Exposure Notes

Ports are bound for LAN access. External access is not provided via public reverse proxy or router port-forwarding; the environment follows a zero-trust inspired model for remote access.
