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
- No database workloads (SQLite/PostgreSQL) on SMB mounts

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
- Paperless → /mnt/mergerfs/Paperless (service data: media, thumbnails, exports)
- openwebui → /mnt/mergerfs/openwebui
- Postgres-backups → /mnt/mergerfs/Postgres-Backups (write path for pg_dump output from LXC260)

Ownership enforcement:

- force user = storage
- force group = storage
- create mask = 0660
- directory mask = 0770

This ensures consistent file ownership regardless of client context.

### Ingest Shares (Cross-Service Write Path)

Paperless consumption directories are exposed as separate shares per user,
allowing Nextcloud External Storage to write files for automatic ingestion.

- Paperless-ingest-user1 → /mnt/mergerfs/Paperless/consumption/user1
- Paperless-ingest-user2 → /mnt/mergerfs/Paperless/consumption/user2

These shares use a dedicated SMB user (`paperless-ingest`) with write access
scoped to the consumption subdirectories only.

Ownership enforcement follows the same model as other RW shares
(`force user = storage`, `force group = storage`).

Paperless workflows match documents by consumption subdirectory path
and assign ownership to the corresponding Paperless user.

---

### Desktop Shares

The `storage` OS user doubles as the desktop identity for direct media library access.
Four shares expose the media library paths read-write to the admin workstation:

- Filme → /mnt/mergerfs/Filme
- Serien → /mnt/mergerfs/Serien
- Audiobooks → /mnt/mergerfs/Audiobooks
- Books → /mnt/mergerfs/Books

These shares have no `create mask` / `directory mask` set (inherits filesystem defaults)
because no other service identity writes to these paths alongside the desktop user.

On the desktop, all five shares are mounted via `/etc/fstab` (CIFS, `vers=3`, `_netdev`, `nofail`)
using a credentials file at `/etc/samba/credentials-storage`.

---

### Read-Only Consumer Shares

Media services receive read-only access:

- Jellyfin (`media-jf`) → /mnt/mergerfs (full pool, RO)
- Audiobookshelf (`media-abs`) → /mnt/mergerfs (full pool, RO)
- Calibre-Web (`books-svc`) → /mnt/mergerfs/Books (scoped to Books, RO)

These shares are:

- read only = yes
- not browseable
- bound to dedicated service users

This reduces risk of accidental modification or deletion.

---

### Gaming Share (Retro ROMs)

The `[roms]` share exposes the retro gaming ROM library with a three-user access model:

- `storage` — read-write; primary workflow user on the Gaming PC for ROM and BIOS file management (consistent with all other write operations on VM102)
- `roms-admin` — read-write; used by ES-DE scraper on the Gaming PC for writing `media/` and `gamelists/`
- `roms` — read-only; used by all other gaming clients (`tag:gaming`)

Path: `/mnt/mergerfs/roms/`

Directory layout:

```
roms/
├── ps1/  ps2/  n64/  gamecube/  wii/  gbc/  gba/  nds/
├── bios/       — shared BIOS files (mounted as RetroArch system path on Windows/Linux)
├── media/      — scraped artwork, screenshots, videos (written by roms-admin)
└── gamelists/  — gamelist.xml per console (written by roms-admin)
```

Access is enforced at three levels:
1. **Tailscale ACL** — `tag:gaming` can only reach `tag:storage:445`; no other infrastructure is reachable
2. **Samba `valid users`** — share only accepts `roms` and `roms-admin` credentials
3. **Samba permissions** — `roms` is read-only; `roms-admin` has write access

See: [Retro Gaming Stack](../services/retro-gaming.md)

---

## Security Posture

- SMB3 only
- Mandatory signing
- User-based authentication
- No anonymous access
- No public exposure
- Access restricted to LAN and Tailscale overlay
- No implicit subnet-wide trust beyond defined ACL model

SMB is not used for internet-facing services.

---

## Architectural Role

Samba acts as a segmentation and identity boundary between:

- Storage layer (VM102)
- Compute layer (VM100)
- Service LXCs

It is not used for public file sharing.

It is an internal platform component.

## Failure Impact

If Samba becomes unavailable:

- All dependent services lose access to their storage paths
- Containers may start but fail due to missing mounts
- Monitoring should detect mount and service degradation

This reinforces that VM102 represents a single storage failure domain.

## Reference Configuration

Sanitized `smb.conf` for VM102: [snippets/storage/smb.conf.storage-vm102.sanitized.conf](../../snippets/storage/smb.conf.storage-vm102.sanitized.conf)
