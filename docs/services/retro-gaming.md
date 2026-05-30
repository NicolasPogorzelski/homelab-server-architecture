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
| Artwork + gamelists | Share (`media/`, `gamelists/`) | Media via ES-DE `MediaDirectory` setting; gamelists via symlink (mother RW, clients read-only) |

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
//<vm102-address>/roms  /mnt/roms  cifs  credentials=/etc/samba/credentials/roms,uid=1000,gid=1000,iocharset=utf8,vers=3.1.1,_netdev,nofail,x-systemd.automount  0  0
```

- Mother client (Gaming PC): use `roms-admin` (read-write) + VM102 LAN IP
- Read-only clients (Notebook, etc.): use `roms` (read-only) + VM102 Tailscale IP
- `vers=3.1.1`: explicitly negotiates SMB 3.1.1 — required; `vers=3.0` returns EOPNOTSUPP against this Samba server configuration
- `x-systemd.automount`: lazy mount triggered on first access instead of at boot — avoids failures when Tailscale is slower to start than `_netdev` mount processing

### Arch / CachyOS specifics

```bash
paru -S emulationstation-de retroarch
```

Cores are not available via RetroArch's built-in core downloader on Arch. Install individually:

```bash
paru -S libretro-mgba     # GBA / GBC
```

Search available cores: `paru -Ss libretro-`


### Fedora specifics

**ES-DE:** no native package, not on Flathub — distributed as AppImage only. Download the latest
Linux x64 AppImage from [es-de.org](https://es-de.org) and make it executable:

```bash
mkdir -p ~/Applications
curl -L "<download-url-from-es-de.org>" -o ~/Applications/ES-DE.AppImage
chmod +x ~/Applications/ES-DE.AppImage
```

Desktop integration for GNOME (extract embedded `.desktop` file and icon):

```bash
~/Applications/ES-DE.AppImage --appimage-extract
mkdir -p ~/.local/share/applications ~/.local/share/icons/hicolor/scalable/apps
sed "s|Exec=es-de|Exec=$HOME/Applications/ES-DE.AppImage|" \
  ~/squashfs-root/org.es_de.frontend.desktop \
  > ~/.local/share/applications/es-de.desktop
cp ~/squashfs-root/org.es_de.frontend.svg ~/.local/share/icons/hicolor/scalable/apps/
update-desktop-database ~/.local/share/applications/
rm -rf ~/squashfs-root
```

**RetroArch:** install via Flatpak, then grant access to the ROM mount:

```bash
flatpak install -y flathub org.libretro.RetroArch
flatpak override --user --filesystem=/mnt/roms org.libretro.RetroArch
```

**RetroArch configuration** (no GUI required — edit config directly):

```bash
CONFIG=~/.var/app/org.libretro.RetroArch/config/retroarch/retroarch.cfg
CORES_DIR=~/.var/app/org.libretro.RetroArch/config/retroarch/cores
mkdir -p "$CORES_DIR"
printf 'system_directory = "/mnt/roms/bios"\nlibretro_directory = "%s"\n' "$CORES_DIR" >> "$CONFIG"
```

**Cores** — download all six directly from the libretro buildbot (no RetroArch GUI required):

```bash
CORES_DIR=~/.var/app/org.libretro.RetroArch/config/retroarch/cores
BASE=https://buildbot.libretro.com/nightly/linux/x86_64/latest
for CORE in mednafen_psx_hw_libretro mupen64plus_next_libretro dolphin_libretro mgba_libretro melonds_libretro pcsx2_libretro; do
  curl -sL "$BASE/${CORE}.so.zip" -o /tmp/${CORE}.zip
  unzip -oq /tmp/${CORE}.zip -d "$CORES_DIR"
  rm /tmp/${CORE}.zip
done
```

### Shared metadata: media + gamelists

ES-DE (3.x) keeps metadata in two places, and they relocate to the share by different mechanisms:

| Part | Default location | Relocatable via setting? | Mechanism |
|---|---|---|---|
| Game media (images/videos) | `~/ES-DE/downloaded_media/` | Yes | Main Menu → Other Settings → **Game Media Directory** = `/mnt/roms/media` (key `MediaDirectory` in `es_settings.xml`) |
| Gamelists (`gamelist.xml` text) | `~/ES-DE/gamelists/` | No | Symlink `~/ES-DE/gamelists` → `/mnt/roms/gamelists` (ES-DE follows symlinks) |

**Mother client (read-write)** — migrate existing local gamelists once, then symlink (ES-DE closed):

```bash
cp -r ~/ES-DE/gamelists/. /mnt/roms/gamelists/   # one-time migration of existing scrapes
mv ~/ES-DE/gamelists ~/ES-DE/gamelists.bak       # back up local dir before replacing
ln -s /mnt/roms/gamelists ~/ES-DE/gamelists      # local path now points at the share
```

The mother client keeps `SaveGamelistsMode = always` — it is the only writer. Every future scrape and metadata edit lands directly on the share through the symlink (no further copying).

**Read-only clients** — symlink to the same share, then stop ES-DE from writing (ES-DE closed):

```bash
mv ~/ES-DE/gamelists ~/ES-DE/gamelists.bak       # skip if it does not exist
ln -s /mnt/roms/gamelists ~/ES-DE/gamelists
```

Set `SaveGamelistsMode = never` so ES-DE never tries to write `lastplayed`/`timesplayed` back to the read-only share (Main Menu → Other Settings → "Save metadata on exit", or directly in `es_settings.xml`):

```bash
sed -i '/SaveGamelistsMode/ s/value="always"/value="never"/' ~/ES-DE/settings/es_settings.xml
```

> **Performance caveat:** ES-DE upstream warns that media/gamelists on a network share can be slow and recommends NFS over SMB (10–30× faster in their testing). In practice `gamelist.xml` files are small and read once at startup, so SMB is fine for them; large media collections browsed continuously are where NFS matters.

> **ES-DE data dir:** ES-DE 3.x uses `~/ES-DE/`; legacy versions use `~/.emulationstation/` — adjust paths accordingly.

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
| Gaming PC (mother client) | CachyOS | Complete |
| Notebook | Fedora | In progress |
| Shield | Android TV | Planned |
| Phone | Android | Planned |

## Related Documents

- [VM102 Node](../nodes/vm102.md)
- [Samba Configuration](../platform/samba.md)
- [Tailscale ACL](../platform/tailscale-acl.md)
- [Storage Design](../platform/storage-design.md)
