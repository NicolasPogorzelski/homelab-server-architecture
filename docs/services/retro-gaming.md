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
| `roms-admin` | read-write | Gaming PC (mother client, `tag:admin`) |
| `roms` | read-only | All other gaming clients (`tag:gaming`) |

## Client Software

| Component | Software | Notes |
|---|---|---|
| Frontend | ES-DE | Runs per client; reads gamelists from share |
| Emulator | RetroArch | Runs per client |
| Scraper | ScreenScraper via ES-DE | Run once from mother client only |

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
| `tag:admin` | `tag:storage` (VM102) | 445 | Allowed (ROM share, read-write) |
| Any | Gaming clients | any other | Denied |

Three security layers:

| Layer | Controls | Mechanism |
|---|---|---|
| Reachable nodes | Only VM102 + other gaming clients | Tailscale ACL |
| Reachable ports | 445 (SMB) + 55435 (Netplay) | Tailscale ACL |
| Reachable shares | Only `[roms]` | Samba `valid users` |

External friends can be invited as Tailscale users; `tag:gaming` is assigned by the admin.
Friends cannot self-assign the tag (tagOwners: autogroup:admin).

## Related Documents

- [VM102 Node](../nodes/vm102.md)
- [Samba Configuration](../platform/samba.md)
- [Tailscale ACL](../platform/tailscale-acl.md)
- [Storage Design](../platform/storage-design.md)
