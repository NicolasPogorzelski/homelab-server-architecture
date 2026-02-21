# Samba Architecture (Storage VM - VM102)

The Storage VM exposes selected paths from the MergerFS pool via SMB3.

This layer enforces strict service segmentation and least-privilege access.

---

## Design Goals

- Provide stable network mounts for services
- Avoid UID/GID ambiguity across LXC namespace boundaries
- Enforce read-write access only where required
- Minimize blast radius of service compromise
- Maintain deterministic ownership behavior

---

## Why SMB Instead of NFS?

NFS was initially evaluated but introduced complexity when combined with:

- Unprivileged LXC containers
- UID/GID shifting (100000+ namespace mapping)
- Root-squash behavior
- Cross-boundary identity consistency

SMB was selected because it allows:

- Explicit per-service authentication
- Deterministic ownership enforcement (`force user`, `force group`)
- Controlled read-only exports
- Clear identity boundaries

The decision prioritizes operational predictability over theoretical performance.

---

## Share Model

### Read-Write Shares (Service Identities)

- Nextcloud → /mnt/mergerfs/Nextcloud
- Vaultwarden → /mnt/mergerfs/Vaultwarden

Ownership enforcement:

- force user = storage
- force group = storage
- create mask = 0660
- directory mask = 0770

This ensures consistent file ownership regardless of client context.

---

### Read-Only Consumer Shares

Media services receive read-only access:

- Jellyfin
- Audiobookshelf
- Calibre-Web

These shares are:

- read only = yes
- not browseable
- bound to dedicated service users

This reduces risk of accidental modification or deletion.

---

## Security Posture

- SMB3 only
- Mandatory signing
- User-based authentication
- No anonymous access
- No public exposure
- Access restricted to LAN and Tailscale overlay

---

## Architectural Role

Samba acts as a segmentation and identity boundary between:

- Storage layer (VM102)
- Compute layer (VM100)
- Service LXCs

It is not used for public file sharing.

It is an internal platform component.

