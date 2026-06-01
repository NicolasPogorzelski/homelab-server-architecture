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
/mnt/mergerfs/roms/            (mounted as /mnt/roms on clients)
├── psx/          — PlayStation 1 (multi-disc games use .m3u + subfolder, see below)
├── ps2/
├── n64/
├── gamecube/
├── wii/
├── gbc/
├── gba/
├── nds/          — Nintendo DS (.nds files directly, no subfolder structure)
├── bios/         — shared BIOS files (Windows/Linux clients mount directly)
├── saves/        — in-game saves (.srm), central across clients (see "Cross-device saves")
├── states/       — save states (.state), central across clients (see "Cross-device saves")
├── media/        — artwork, screenshots, videos (written by scraper)
└── gamelists/    — gamelist.xml per console (written by scraper)
```

Console subdirectory names follow the ES-DE convention (`psx`, `nds`, …), not vendor labels like `ps1`.

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

| Console | Core | libretro identifier |
|---|---|---|
| PSX | Beetle PSX HW | `mednafen_psx_hw_libretro` |
| PS2 | PCSX2 | `pcsx2_libretro` |
| N64 | Mupen64Plus-Next | `mupen64plus_next_libretro` |
| GameCube / Wii | Dolphin | `dolphin_libretro` |
| GBC / GBA | mGBA | `mgba_libretro` |
| NDS | melonDS DS | `melondsds_libretro` |

Cores are **not portable between clients** — each architecture (x86_64 Linux, Windows DLL, ARM
Android) needs its own build. Install per client.

**Core source — buildbot, not the distro package manager.** On the mother client (CachyOS) the
pacman cores (`libretro-beetle-psx`, `libretro-melonds`, …) were removed; all cores now come from
the official [libretro buildbot](https://buildbot.libretro.com) via the RetroArch GUI core
downloader. This keeps every client on the same upstream build (important for save-state
compatibility) and avoids distro-lag. The GUI downloader requires three keys in `retroarch.cfg`
(see "RetroArch base configuration") — `menu_show_core_updater`,
`core_updater_show_experimental_cores`, and the buildbot URLs. Fedora clients pull the same
`.so` files headless with `curl` (see "Fedora specifics").

> **NDS core-name gotcha:** the correct core is **melonDS DS** (`melondsds_libretro`), not the
> older standalone **melonDS**. ES-DE picks the first `<command>` listed for the system in
> `es_systems.xml`; if that entry references a core you have not installed, the launch fails
> silently. Verify the system's command maps to `melondsds`.

## BIOS Files

- **Windows / Linux clients**: RetroArch System Directory (`system_directory`) points to the
  mounted `bios/` folder on the share (`/mnt/roms/bios`).
- **Android / Android-TV**: copy locally once (PSX ~500 KB, PS2 ~4 MB, GBA ~16 KB, NDS ~16 KB).
  Android does not support reliable SMB mounting as a RetroArch system path.

### PSX BIOS

Beetle PSX HW requires a region BIOS (HLE is not supported for this core). Place in `bios/`:

| File | Region | MD5 |
|---|---|---|
| `scph5501.bin` | NTSC-U (USA) | `490f666e1afb15b7362b406ed1cea246` |
| `scph5502.bin` | PAL (Europe) | `32736f17079d0b2b7024407c39bd3050` |
| `PSXONPSP660.BIN` | PSP-derived (region-free fallback) | — |

Match the BIOS region to the game's region (PAL game → `scph5502.bin`).

### NDS BIOS

Optional — melonDS DS runs without real BIOS using HLE. For higher accuracy, add `bios7.bin`,
`bios9.bin`, and `firmware.bin` to `bios/`.

## ROM Formats & Per-Console Layout

### PSX — CHD and multi-disc

- **Format:** CHD (compressed, single-file, reliable) is preferred over raw `.bin`/`.cue`.
  Convert with `chdman createcd -i Game.cue -o Game.chd` (`chdman` ships with MAME tools).
- **Source rip caveat:** the source `.bin`/`.cue` must contain the *full* track list (data +
  audio). Single-track rips stripped of audio tracks will not convert/play correctly.
- **Single-disc games:** drop the `.chd` directly in `psx/`.
- **Multi-disc games:** use an `.m3u` playlist so RetroArch treats the discs as one title and
  carries the memory card across discs:

```
psx/
├── Game.m3u                 — playlist: one relative path per line
└── Game/
    ├── noload.txt           — empty file; stops ES-DE scanning the subfolder
    ├── Game (Disc 1).chd
    └── Game (Disc 2).chd
```

`.m3u` content (paths relative to the `psx/` directory):

```
Game/Game (Disc 1).chd
Game/Game (Disc 2).chd
```

`noload.txt` prevents ES-DE from creating a stray `<folder>` entry for the disc subfolder — ES-DE
auto-generates folder entries whenever a subdirectory is present, and the empty marker suppresses
that scan so only the `.m3u` shows up as a single game.

#### Beetle PSX HW core options

Stored per-core at `~/.config/retroarch/config/Beetle PSX HW/Beetle PSX HW.opt`:

| Option | Value | Why |
|---|---|---|
| `beetle_psx_hw_renderer` | `hardware` | Hardware (Vulkan/OpenGL) rendering instead of software |
| `beetle_psx_hw_cpu_dynarec` | `execute` | Enables the dynarec (dynamic recompiler) for full speed |
| `beetle_psx_hw_cd_fastload` | `8x` | Faster CD seeks — important when ROMs sit on a network mount |

### NDS

No special structure — place `.nds` files directly in `nds/`.

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
| RetroArch cores | Local (per client) | Not on share — install from the libretro buildbot (GUI core downloader or `curl`) |
| Saves + states | Share (`saves/`, `states/`) | Central via `savefile_directory` / `savestate_directory` — currently RW mother client only |
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

### Arch / CachyOS specifics (mother client)

```bash
paru -S emulationstation-de retroarch
```

**Cores: use the RetroArch GUI core downloader (buildbot), not pacman.** Earlier this client used
the `libretro-*` pacman packages; they were removed in favour of the buildbot so every client runs
the same upstream build. Online Updater → Core Downloader inside RetroArch installs into
`libretro_directory`. To expose the downloader (and experimental cores like `pcsx2`), the config
needs:

```
menu_show_core_updater = "true"
core_updater_show_experimental_cores = "true"
core_updater_buildbot_cores_url  = "https://buildbot.libretro.com/nightly/linux/x86_64/latest/"
core_updater_buildbot_assets_url = "https://buildbot.libretro.com/assets/"
```

#### RetroArch base configuration (`~/.config/retroarch/retroarch.cfg`)

| Key | Value | Why |
|---|---|---|
| `libretro_directory` | `~/.config/retroarch/cores` | Where GUI-downloaded cores land |
| `libretro_info_path` | `/usr/share/libretro/info` | Core `.info` metadata (from the `retroarch` package) |
| `system_directory` | `/mnt/roms/bios` | Shared BIOS on the NAS mount |
| `savefile_directory` | `/mnt/roms/saves` | Central in-game saves (`.srm`) |
| `savestate_directory` | `/mnt/roms/states` | Central save states (`.state`) |
| `video_driver` | `vulkan` | Native Vulkan path on the RX 7900 XT (Wayland) |

> **Save the config from inside RetroArch.** RetroArch rewrites `retroarch.cfg` on exit and will
> overwrite hand-edited values. After changing settings in the GUI, run
> Settings → Configuration → **Save Current Configuration**, then quit — otherwise the on-exit
> write clobbers your edits.


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
for CORE in mednafen_psx_hw_libretro mupen64plus_next_libretro dolphin_libretro mgba_libretro melondsds_libretro pcsx2_libretro; do
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

### Adding a new game

1. **Single-disc:** copy the ROM into `/mnt/roms/<system>/`.
2. **Multi-disc (PSX):** put the `.m3u` in `/mnt/roms/psx/`, the disc files in a subfolder, and an
   empty `noload.txt` in that subfolder (see "ROM Formats").
3. Restart ES-DE — the game appears automatically.
4. Scrape it: select the game → right-click / menu → Scrape (mother client only).

> **ES-DE gotchas:**
> - ES-DE rewrites `gamelist.xml` on start; hand-edited entries can be lost. Let the scraper write
>   metadata, or set `SaveGamelistsMode = never` on read-only clients.
> - A subfolder under a system dir auto-creates a `<folder>` entry — suppress with `noload.txt`.
> - Wrong core launch: ES-DE uses the first `<command>` in `es_systems.xml`; make sure it maps to
>   an installed core (the melonDS DS vs melonDS trap).

## Cross-device saves

In-game saves (`.srm`) and save states (`.state`) are pointed at the share via RetroArch's
`savefile_directory` (`/mnt/roms/saves`) and `savestate_directory` (`/mnt/roms/states`), so a save
made on one client is visible to the others.

**Current state:** only read-write clients (the Gaming PC) can write there — the `roms` user is
read-only and `[roms]` must stay that way. So central saves/states are mother-client-only today.

### Decided target design (not yet implemented)

Scope: **own devices only** (Gaming PC, Notebook, Shield, Phone) — friends/netplay guests are
excluded from save sync by design.

Two enforcement layers, deliberately separated:

| Layer | Mechanism | Job |
|---|---|---|
| Data (the real gatekeeper) | Samba: a **separate writable `[saves]` share** with a dedicated `saves` user in `valid users` | Only devices holding the `saves` credential can write. `[roms]` stays read-only. |
| Network (documentation/future-proofing) | Tailscale tag `tag:gaming-trusted` for own devices | Marks own devices. Today grants no *extra* network access — guests keep `[roms]` (445), so both tags reach VM102:445; the `saves` credential is what actually distinguishes them. |

Design choices:
- **Separate `[saves]` share**, not a writable `[roms]` — preserves ROM/metadata hardening.
- **Dedicated `saves` user** (RW on `[saves]` only), not reuse of `storage`/`roms-admin` — least
  privilege; read-only clients get a save credential without gaining ROM write access.
- **One flat shared folder** (`saves/` + `states/`), not per-client subfolders — a shared save dir
  is the whole point; RetroArch keys files by content name so the same game maps to the same file.
- Per client: RetroArch `savefile_directory`/`savestate_directory` → the `[saves]` mount
  (e.g. `/mnt/saves/saves`, `/mnt/saves/states`), replacing the interim `/mnt/roms/...` paths.

Access matrix (target):

| Source (tag) | Destination | Port | Credential / access |
|---|---|---|---|
| `tag:gaming-trusted` | VM102 | 445 | `[roms]` (RO `roms` / RW `storage` on mother) + `[saves]` RW (`saves`) |
| `tag:gaming` (guests) | VM102 | 445 | `[roms]` RO only |
| both | each other | 55435 | Netplay |

Caveats:
- Save states are sensitive to the exact core build — keep all clients on the same buildbot core.
- No simultaneous play: last write wins (no locking). Acceptable for single-player, single-user.
- **Shield (Android TV): unverified** whether RetroArch can write `savefile_directory` directly to
  an SMB path. Verify on-device first; if it cannot, the fallback is file sync (e.g. Syncthing)
  with the same `[saves]` target — the tag/share model is unchanged, only the transport differs.

## Open items (mother client)

Configured and working: mounts, cores, PSX + NDS, central saves/states (RW), shared media +
gamelists, DualSense controller. Still to do:

- Hotkeys (DualSense: `Select` as hotkey-enabler)
- Run-ahead (latency reduction)
- Per-system shaders
- ES-DE scraper credentials (ScreenScraper) + theme
- Audio-latency tuning
- Cross-device saves (design decided, see above): create `[saves]` share + `saves` user, add
  `tag:gaming-trusted`, repoint client save dirs; verify SMB-write on Shield

## Per-client notes

- **Cores are not portable** — reinstall per client/architecture (x86_64 Linux `.so`, Windows DLL,
  ARM Android).
- **RetroArch paths** differ per client (Flatpak vs native; the SMB mountpoint may not be `/mnt/roms`).
- **Nvidia Shield Pro (Tegra X1+):** enable rewind only for 2D systems — 3D cores are too heavy.

## Related Documents

- [VM102 Node](../nodes/vm102.md)
- [Samba Configuration](../platform/samba.md)
- [Tailscale ACL](../platform/tailscale-acl.md)
- [Storage Design](../platform/storage-design.md)
