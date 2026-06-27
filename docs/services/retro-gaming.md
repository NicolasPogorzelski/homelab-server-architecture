# Retro Gaming Stack

A client-side retro gaming setup backed by centralized ROM storage on VM102.
No dedicated server component. No new LXC.

## Architecture

The stack has two tiers:

- **Storage tier** — VM102 hosts a Samba share (`[roms]`) with the ROM library, BIOS files,
  artwork, and gamelist metadata under `/mnt/mergerfs/roms/`.
- **Client tier** — each gaming client (PC, TV box, handheld) runs ES-DE as a frontend
  and RetroArch as an emulation backend. Clients mount the `[roms]` share over SMB via Tailscale.

Metadata scraping (artwork, descriptions, videos) is performed once from the "mother client"
(Gaming PC, `tag:admin`), which has write access to `media/` and `gamelists/` on the share.
All other clients consume the pre-scraped metadata read-only.

## ROM Share Layout

```
/mnt/mergerfs/roms/
├── ps1/
├── ps2/
├── n64/
├── gamecube/
├── wii/
├── gbc/
├── gba/
├── nds/
├── bios/         — shared BIOS files (Windows/Linux clients mount directly)
├── media/        — artwork, screenshots, videos (written by scraper)
└── gamelists/    — gamelist.xml per console (written by scraper)
```

PS3 and Switch are intentionally excluded. Switch can be added later (new subdirectory + core per client).

## Samba Users

Two Samba identities for the `[roms]` share:

| User | Access | Used by |
|---|---|---|
| `storage` | read-write | Gaming PC (mother client) — primary workflow user for ROM and BIOS management |
| `roms-admin` | read-write | Gaming PC — used by ES-DE scraper for writing `media/` and `gamelists/` |
| `roms` | read-only | All other gaming clients (`tag:gaming`) |

## Client Software

| Component | Software | Notes |
|---|---|---|
| Frontend | ES-DE | Runs per client; reads gamelists from share |
| Emulator | RetroArch | Runs per client |
| Scraper | TheGamesDB or ScreenScraper via ES-DE | Run once from mother client only; TheGamesDB requires no account |

### RetroArch Cores

| Console | Core |
|---|---|
| PS1 | Beetle PSX HW |
| PS2 | PCSX2 |
| N64 | Mupen64Plus-Next |
| GameCube / Wii | Dolphin |
| GBC / GBA | mGBA |
| NDS | melonDS |

## BIOS Files

- **Windows / Linux clients**: RetroArch System Directory points to the mounted `bios/` folder on the share.
- **Android / Android-TV**: copy locally once (PS1 ~500 KB, PS2 ~4 MB, GBA ~16 KB, NDS ~16 KB).
  Android does not support reliable SMB mounting as a RetroArch system path.

## Netplay

Peer-to-peer via Tailscale. NAT traversal is handled by Tailscale (WireGuard).
No relay server required.

- Port: 55435 (RetroArch default)
- ACL allows `tag:gaming → tag:gaming:55435`
- Tailscale peers connect directly after ACL permits the flow

## Access Model (Zero Trust)

- No public ingress / no router port forwarding.
- All traffic flows over Tailscale (WireGuard-encrypted).
- Gaming clients are isolated in `tag:gaming` — they can only reach VM102:445 (SMB) and other gaming clients on port 55435 (Netplay).
- The Gaming PC (mother client) retains `tag:admin` and has read-write Samba access via `roms-admin`.
- Network policy enforced via Tailscale ACL. See: [Tailscale ACL](../platform/tailscale-acl.md)

| Source | Destination | Port | Access |
|---|---|---|---|
| `tag:gaming` | `tag:storage` (VM102) | 445 | Allowed (ROM share, read-only) |
| `tag:gaming` | `tag:gaming` | 55435 | Allowed (Netplay) |
| `tag:admin` (`storage` user) | `tag:storage` (VM102) | 445 | Allowed (ROM share, read-write) |
| Any | Gaming clients | any other | Denied |

Three security layers:

| Layer | Controls | Mechanism |
|---|---|---|
| Reachable nodes | Only VM102 + other gaming clients | Tailscale ACL |
| Reachable ports | 445 (SMB) + 55435 (Netplay) | Tailscale ACL |
| Reachable shares | Only `[roms]` | Samba `valid users` |

External friends can be invited as Tailscale users; `tag:gaming` is assigned by the admin.
Friends cannot self-assign the tag (tagOwners: autogroup:admin).

## Client Setup

### Per-client vs shared

| Component | Location | Notes |
|---|---|---|
| RetroArch cores | Local (per client) | Not on share — install via package manager |
| Controller config | Local (per client) | Configure in RetroArch settings |
| ROMs | Share | Managed centrally on VM102 |
| BIOS files | Share (`bios/`) | Linux: point RetroArch system dir to share mount |
| Artwork + gamelists | Share (`media/`, `gamelists/`) | Scraped once from mother client; consumed by all |

### Linux: mounting the ROM share

Install CIFS support if not present:
- Arch/CachyOS: `paru -S cifs-utils`
- Fedora: `dnf install cifs-utils`

Create credentials file at `/etc/samba/credentials/roms` (permissions: `chmod 600`, owner `root:root`):

```
username=<samba-user>
password=<password>
```

Create mountpoint: `sudo mkdir -p /mnt/roms`

Add to `/etc/fstab`:

```
//<vm102-address>/roms  /mnt/roms  cifs  credentials=/etc/samba/credentials/roms,uid=1000,gid=1000,iocharset=utf8,_netdev,nofail  0  0
```

- Mother client (Gaming PC): use `roms-admin` (read-write) + VM102 LAN IP
- Read-only clients (Notebook, etc.): use `roms` (read-only) + VM102 Tailscale IP

### Bazzite specifics

EmulationStation DE and RetroArch are available via the built-in Bazzite package manager / Flatpak.
Verify with `ujust` helpers or install via Discover / command line:

```bash
flatpak install flathub org.libretro.RetroArch
flatpak install flathub net.retrodeck.retrodeck   # alternative: RetroDECK
```

RetroArch cores are available from within the Flatpak via the built-in core downloader.

### Arch / CachyOS specifics

```bash
paru -S emulationstation-de retroarch
```

Cores are not available via RetroArch's built-in core downloader on Arch. Install individually:

```bash
paru -S libretro-mgba     # GBA / GBC
```

Search available cores: `paru -Ss libretro-`

### Scraper

Run once from the mother client only. Results land on the share and are consumed by all clients.

| Scraper | Account required | Coverage |
|---|---|---|
| TheGamesDB | No | Good for mainstream consoles |
| ScreenScraper | Yes (free, screenscraper.fr) | Comprehensive |

Configure in ES-DE: Main Menu → Scraper → Scraper Source.

### Client status

| Client | OS | Status |
|---|---|---|
| Gaming PC (mother client) | Bazzite | Needs re-verification after distro change |
| Notebook | Fedora | Planned |
| Shield | Android TV | Planned |
| Phone | Android | Planned |

## Related Documents

- [VM102 Node](../nodes/vm102.md)
- [Samba Configuration](../platform/samba.md)
- [Tailscale ACL](../platform/tailscale-acl.md)
- [Storage Design](../platform/storage-design.md)
