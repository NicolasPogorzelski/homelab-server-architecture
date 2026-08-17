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

- Nextcloud -> /mnt/mergerfs/Nextcloud
- Vaultwarden -> /mnt/mergerfs/Vaultwarden
- Paperless -> /mnt/mergerfs/Paperless (service data: media, thumbnails, exports)
- openwebui -> /mnt/mergerfs/openwebui
- Postgres-backups -> /mnt/mergerfs/Postgres-Backups (write path for pg_dump output from LXC260)
- DB-Backups -> /mnt/mergerfs/DB-Backups (write path for the MariaDB dump from LXC210, added
  2026-08-15; a share of its own rather than a directory inside the Nextcloud export, so whatever
  reaches the user data does not also reach its backup)

Ownership enforcement:

- force user = storage
- force group = storage
- create mask = 0660
- directory mask = 0770

This ensures consistent file ownership regardless of client context.

**These masks describe the write path through Samba, and nothing else.** They apply at the moment
Samba creates an object and never afterwards, so a directory created over SSH bypasses them and a
file predating a mask keeps its old mode indefinitely. What the objects on the disks are actually
supposed to look like is a separate statement, kept in
[storage-permissions.md](storage-permissions.md) and verified by a daily check. That document
exists because the gap between these two things stayed open from the pool's creation on 2025-12-26
until 2026-08-16 without producing a symptom.

### Ingest Shares (Cross-Service Write Path)

Paperless consumption directories are exposed as separate shares per user,
allowing Nextcloud External Storage to write files for automatic ingestion.

- Paperless-ingest-user1 -> /mnt/mergerfs/Paperless/consumption/user1
- Paperless-ingest-user2 -> /mnt/mergerfs/Paperless/consumption/user2

These shares use a dedicated SMB user (`paperless-ingest`) with write access
scoped to the consumption subdirectories only.

Ownership enforcement follows the same model as other RW shares
(`force user = storage`, `force group = storage`).

Paperless workflows match documents by consumption subdirectory path
and assign ownership to the corresponding Paperless user.

---

### Workstation Shares

The `storage` OS user doubles as the admin-workstation identity for direct media library access.
Four shares expose the media library paths read-write to the admin workstation:

- Filme -> /mnt/mergerfs/Filme
- Serien -> /mnt/mergerfs/Serien
- Audiobooks -> /mnt/mergerfs/Audiobooks
- Books -> /mnt/mergerfs/Books

These shares have no `create mask` / `directory mask` set (inherits filesystem defaults)
because no other service identity writes to these paths alongside the workstation user.

On the admin workstation these four are mounted via `/etc/fstab` using a credentials file at
`/etc/samba/credentials-storage`. Measured 2026-08-17: `vers=3.1.1`, `_netdev`, `soft` and
`x-systemd.automount` - not the `nofail` this paragraph claimed. The distinction is the KE-15 one
and worth keeping straight: `nofail` lets a failed boot-time mount pass silently and never retries,
whereas `x-systemd.automount` defers the mount to first access and therefore survives VM102 being
unavailable at boot. The workstation also mounts one share that is outside the scope of this
document, which is why a count stated here would not match what `findmnt` shows.

---

### Read-Only Consumer Shares

Media services receive read-only access:

- Jellyfin: `media-jf-filme` -> /mnt/mergerfs/Filme, `media-jf-serien` -> /mnt/mergerfs/Serien (RO)
- Audiobookshelf: `media-abs-audiobooks` -> /mnt/mergerfs/Audiobooks, `media-abs-podcasts` -> /mnt/mergerfs/Podcasts (RO)
- Calibre-Web (`books-svc`) -> /mnt/mergerfs/Books (RO)

Until 2026-08-16 the two media consumers held a single share each, pointing at the whole pool.
The directory modes kept them inside their own libraries, but the share itself did not. The
scoped shares above are evaluated before any filesystem permission and therefore hold even if a
directory mode is ever loosened. The superseded `[media-jf]` and `[media-abs]` definitions have
since been removed - confirmed by `testparm -s` on 2026-08-17, which no longer lists them, as the
old mounts on VM100 had cleared with the nightly power-off.

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
- No implicit subnet-wide trust beyond defined ACL model

SMB is not used for internet-facing services.

### Binding: known deviation from the platform rule

Samba does not follow the platform binding rule ("services bind to the Tailscale IP, never to
LAN interfaces"). `bind interfaces only = no` makes `smbd` accept on every interface, including
the LAN interface and its globally routable IPv6 address; access control rests entirely on
`hosts allow` / `hosts deny`, which Samba applies *after* accepting the TCP connection.

An earlier version of this section claimed "No public exposure". That was an unverified assertion
and has been removed: port 445 is bound on a world-routable IPv6 address, and what prevents
reachability today is the router's default block on inbound IPv6 plus the absence of any IPv6
entry in `hosts allow` - not the service's binding.

The deviation persists for a reason that is not configuration laziness: **Samba cannot bind an
IPv4 address on `tailscale0` at all.** The interface is a point-to-point TUN device without the
`BROADCAST` flag, and Samba's IPv4 interface selection skips such interfaces. Tried and verified
2026-07-14 with `<ip>/32`, with the bare IP, and with the interface name - none binds the Tailscale
IPv4 address, and an explicit `interfaces` list therefore *removes* the Tailscale SMB path instead
of securing it. (The IPv6 ULA does bind as `/128`, because IPv6 has no broadcast concept.) The
`# Robust: listen on all available interfaces (avoid bind failures)` comment in the live `smb.conf`
is the fossil of an earlier attempt that hit the same wall.

Throughput is not the reason either - measured 2026-07-14, Tailscale costs ~8 % on this link
(741 vs 809 Mbit/s), because same-subnet peers negotiate a direct WireGuard path over the LAN
rather than via a relay.

The boundary therefore lives in the kernel instead of the application. Since 2026-07-14 the
nftables table `inet smb_guard` on VM102 (loaded by `smb-guard.service`) drops inbound TCP/445 over
IPv6 on the LAN interface - closing the world-routable socket - and over IPv4 accepts only VM100
and the Proxmox host, the two nodes that actually mount. Tailscale traffic arrives on `tailscale0`
and is not evaluated. `hosts allow` remains underneath as redundancy.

Reasoning, measurements and the reboot verification: [SMB bind and LAN
access](../decisions/smb-bind-and-lan-access.md). Sources:
[smb-guard.nft](../../snippets/storage/smb-guard.nft),
[smb-guard.service](../../snippets/systemd/smb-guard.service).

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
