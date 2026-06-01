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

### Gaming Share (Retro ROMs)

The `[roms]` share exposes the retro gaming ROM library with a three-user access model:

- `storage` — read-write; primary workflow user on the Gaming PC for ROM and BIOS file management (consistent with all other write operations on VM102)
- `roms-admin` — read-write; used by ES-DE scraper on the Gaming PC for writing `media/` and `gamelists/`
- `roms` — read-only; used by all other gaming clients (`tag:gaming`)

Path: `/mnt/mergerfs/roms/`

Directory layout:

```
roms/
├── psx/  ps2/  n64/  gamecube/  wii/  gbc/  gba/  nds/
├── bios/       — shared BIOS files (mounted as RetroArch system path on Windows/Linux)
├── saves/      — in-game saves (.srm), central (currently written by the RW mother client only)
├── states/     — save states (.state), central (currently written by the RW mother client only)
├── media/      — scraped artwork, screenshots, videos (written by roms-admin)
└── gamelists/  — gamelist.xml per console (written by roms-admin)
```

> `saves/` and `states/` are an interim arrangement: only read-write clients (the Gaming PC
> via `storage`/`roms-admin`) can write here. Cross-device save sync for read-only clients
> still requires a separate writable `[saves]` share — see
> [Retro Gaming Stack](../services/retro-gaming.md). Do not loosen `[roms]` permissions for this.

Access is enforced at three levels:
1. **Tailscale ACL** — `tag:gaming` can only reach `tag:storage:445`; no other infrastructure is reachable
2. **Samba `valid users`** — share only accepts `roms` and `roms-admin` credentials
3. **Samba permissions** — `roms` is read-only; `roms-admin` has write access

See: [Retro Gaming Stack](../services/retro-gaming.md)

---

## Security Posture

- SMB3 only (`server min protocol = SMB3` → SMB 3.1.1)
- Mandatory signing (`server signing = mandatory`)
- User-based authentication
- No anonymous access
- No public exposure
- Host-level access allow-list (`hosts allow` / `hosts deny`, default-deny)
- No implicit subnet-wide trust beyond defined ACL model

SMB is not used for internet-facing services.

### Host-Level Access Restriction (`hosts allow`)

`smbd` listens on all interfaces (`0.0.0.0` / `[::]`), so network reachability alone does
**not** grant access. Access to port 445 is scoped by a global default-deny allow-list:

```ini
hosts allow = 127.0.0.1 <tailscale-cgnat-range> <vm100-lan-ip> <proxmox-host-lan-ip> <gaming-pc-lan-ip>
hosts deny  = 0.0.0.0/0
```

Allowed sources — everything else on the physical LAN is denied:

| Source | Path | Why |
|---|---|---|
| localhost | — | Samba-internal / IPC |
| Tailscale CGNAT range | Tailscale | gaming + remote clients (the Tailscale ACL governs which tagged nodes may reach `storage:445`) |
| VM100 | host-internal `vmbr0` | Jellyfin / Audiobookshelf media reads — host-internal bridge, kept on LAN for throughput |
| Proxmox host | host-internal `vmbr0` | mounts service shares, bind-mounted into the service LXCs |
| Gaming PC workstation | physical LAN (static DHCP reservation) | bulk media ingest to the pool + ROM/BIOS management — LAN for throughput |

This is the deliberate model: performance-sensitive, intra-host service traffic uses the
host-internal bridge; remote and gaming clients use Tailscale; the physical LAN is denied by
default and opened only for the few enumerated, trusted hosts that need throughput.

Notes:

- Enforcement is at the **application layer** (`hosts allow`). The Proxmox datacenter firewall
  is currently disabled; enabling it cluster-wide solely to close one port was judged
  disproportionate. Interface binding / firewall scoping remains an optional future hardening step.
- `hosts deny = 0.0.0.0/0` covers IPv4. `smbd` also listens on IPv6 (`[::]`); all current
  clients are IPv4, so an IPv6 deny is deferred until an IPv6 SMB client is introduced.
- Reachability is not visibility: NetBIOS discovery (`nmbd`) may still announce the server on
  the LAN, but the file service (445) refuses unlisted hosts — an unlisted LAN host receives
  `Denied connection`.

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
