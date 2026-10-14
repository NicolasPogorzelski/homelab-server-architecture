# Incident & Recovery: aux-disk Failure and Remote-Access Stabilization (2026-06-25)

Three coupled problems on the single Proxmox host, resolved on 2026-06-25. Before that day the
host had booted into emergency mode after an aux-disk mount failure, and remote access had been
restored with `nofail` on the aux-disk fstab entry.

## Summary

| # | Problem | Outcome |
|---|---|---|
| 1 | Remote access fragile after the lockout; Proxmox web UI unreachable | pveproxy boot race fixed ([KE-12](../known-errors.md#ke-12)); LAN SSH fallback verified |
| 2 | Five service LXCs would not start | Root cause: aux-disk medium errors ([KE-13](../known-errors.md#ke-13)) |
| 3 | Irreplaceable data on the failing disk | Rescued read-only and verified before any repair; no data loss |

The same disk caused the emergency-mode lockout and held the bind-mount sources of the five stopped
containers.

## 1 - Remote access

### 1.1 Lockout cause

The earlier recovery notes named two faults, an aux-disk fsck failure and an unplugged network
cable. The cable was never unplugged. The single cause was the aux-disk mount failure tripping
`local-fs.target`, which drops the host into emergency mode: no network target is reached, so
neither `tailscaled` nor a reachable `sshd` starts. In emergency mode the NIC link LED is on
(driver loaded) but no interface is configured, which made the cable look suspect. `nofail` on the
aux-disk entry lets the boot continue past the failed mount.

### 1.2 pveproxy Tailscale-IP boot race

After the reboot SSH worked and the web UI on `:8006` did not. `pveproxy` binds only the host
Tailscale IP (`/etc/default/pveproxy`, `LISTEN_IP=<tailscale-ip-proxmox-host>`). It started before
`tailscaled` assigned that IP, failed five times with `unable to create socket - Cannot assign
requested address`, and systemd stopped retrying (`start request repeated too quickly`). Same class
as [KE-9](../known-errors.md#ke-9); recorded as [KE-12](../known-errors.md#ke-12).
Decision: [pveproxy boot ordering](../../decisions/pveproxy-tailscale-boot-ordering.md).
Recovery: [runbook](../../../runbooks/platform/pveproxy-tailscale-boot-race.md).

### 1.3 Reachability on that day

A service is reachable only if its binding, the network path and the firewall all allow it:

| Service | Binds to | LAN reachable | Tailscale reachable |
|---|---|---|---|
| `sshd` | `0.0.0.0:22` | Yes - `ssh root@<lan-ip-proxmox>` over wired LAN | Yes |
| Web UI (`pveproxy`) | host Tailscale IP, `:8006` | No - by binding | Yes |

The Proxmox firewall was disabled (no `cluster.fw`/`host.fw`). LAN SSH as break-glass was verified
from the admin workstation (`SSH_CONNECTION` showed the LAN path). Emergency mode removes every
network path at once, so a firewall exception only helps once the network is up. Since 2026-10-01
`lan_guard` restricts LAN inbound on every node; break-glass SSH to the hypervisor remains.

## 2 - aux-disk physical failure

### 2.1 Diagnosis

Five LXCs were stopped: lxc200 (monitoring), lxc211 (Paperless), lxc220 (Calibre-Web), lxc230
(OpenWebUI), lxc260 (PostgreSQL). Each has a bind mount whose source is on `/mnt/aux-disk` (Docker
data-root). With the disk unmounted those paths were missing and Proxmox refused to start the
containers. The containers without an aux-disk dependency kept running.

The disk did not mount because of hardware medium errors, not a filesystem or cabling fault:

```
critical medium error, dev sdb, sector ...   (Unrecovered read error)
```

| SMART attribute | Value |
|---|---|
| Current_Pending_Sector | 7688 |
| Offline_Uncorrectable | 7688 |
| Reported_Uncorrect | 18 |
| Power_On_Hours | ~56800 |

A read-only mount (`-o ro,noload`, no journal replay) succeeded and exposed the full directory
tree: the bad sectors had not hit live metadata.

### 2.2 Rescue method

No `fsck` and no read-write mount until everything was copied off; a read-write `fsck` writes to a
disk with thousands of pending sectors and can turn metadata repair into data loss.

- Source mounted read-only (`-o ro,noload`). vm100's jellyfin-data disk, a raw image file on the
  aux-disk, was loop-mounted read-only to reach the data inside it.
- Per-directory `tar` streamed over SSH to the admin workstation (`<lan-ip-admin-workstation>`,
  wired gigabit) onto its encrypted disk. `tar` keeps ownership and permissions inside the archive,
  so the receiver needs no root and restores keep exact UIDs.
- Most valuable first: databases and configs, then media, then regenerable caches.
- `--ignore-failed-read` with stderr captured; the only messages were `socket ignored`, so no
  medium error occurred during the rescue.

Procedure: [aux-disk failure rescue](../../../runbooks/storage/aux-disk-failure-rescue.md).

### 2.3 Rescue inventory

| Archive | Size | Content |
|---|---|---|
| `postgres.tar` | 187 M | PostgreSQL data directory |
| `paperless.tar` | 9.4 G | Paperless data (incl. containerd layers) |
| `monitoring.tar` | 6.3 G | Prometheus/Grafana data |
| `calibreweb.tar` | 2.1 G | containerd layers (regenerable) |
| `nextcloud.tar` | 61 M | - |
| `jf-jellyfin.tar` | 13 G | Jellyfin library DB, artwork, metadata |
| `audiobookshelf.tar` | 1.6 G | Audiobookshelf DB and covers |
| `calibre-library-metadata.tar` | 528 M | Calibre `metadata.db`, covers, `.opf` (no media) |
| `calibre-web-config.tar` | 260 K | Calibre-Web `app.db` |
| `Archiv.tar` | 45 G | Audiobook archive (media) |

Every archive in the table passed `tar -t`. The disk showed 182 GB allocated against about 95 GB of
live data; the difference was dead space inside vm100's sparse jellyfin-data image (blocks written
once and never released by discard). Copying file by file instead of imaging the disk left it
behind.

## 3 - Media library metadata

Where each library's catalog lives (media files are on the vm102 pool), from the per-service `.env`
files on lxc250:

| Library | Metadata location | Storage | Status |
|---|---|---|---|
| Jellyfin | `/mnt/vm-data/jellyfin` on vm100 (image on the aux-disk) | failing | Rescued (`jf-jellyfin.tar`) |
| Audiobookshelf | `/opt/docker/audiobookshelf` on vm100's root disk | local-lvm | Copied (`audiobookshelf.tar`) |
| Calibre | Calibre-Web `app.db` on lxc220 rootfs; `metadata.db` on the pool | healthy | Copied; catalog already on the pool |

Only Jellyfin's library was on the failing disk. No re-scrape was needed.

At the end of the day the five containers and vm100 stayed down pending a storage decision; the
aux-disk was mounted read-only for the rescue only.

## Configuration changes

One persistent change: the host drop-in `/etc/systemd/system/pveproxy.service.d/wait-tailscale.conf`
(`After=`/`Wants=tailscaled.service`, `ExecStartPre` poll for the Tailscale IP, up to 30 s). The
read-only mounts and vm100 disk mappings used for inspection were transient and removed.

## Follow-up items

1. Permanent home for the data and service restart - done 2026-07-09: no other target had room,
   so the disk went back into service with the five data-roots and vm100's disk on it
   ([KE-13](../known-errors.md#ke-13)).
2. aux-disk replacement - open:
   [remediation plan](../remediation-plan.md#aux-disk-replacement-and-disposal).
3. Docker data-root strategy on `/mnt/aux-disk` - unchanged while the disk is in service; the
   [data-root migration runbook](../../../runbooks/platform/docker-data-root-migration.md) is
   revisited with the replacement.
4. pveproxy gate on the shared script - done 2026-09-12: the `tailscale_boot_gate` role owns it and
   removed the hand-written drop-in ([KE-12](../known-errors.md#ke-12)).
5. Off-site copy - open. The `offsite_backup` role exists and is not deployed; first item of the
   [remediation plan](../remediation-plan.md#off-site-backup).
6. Disk health monitoring - done: `smart_metrics` exports per-attribute SMART data and
   `SmartAttributeDegrading` alerts per disk serial ([KE-13](../known-errors.md#ke-13)).

## Findings

- Emergency mode removes every network path at once; `nofail` on non-critical mounts keeps the
  boot out of it.
- Every service bound to the Tailscale IP needs a wait-for-IP gate
  ([KE-18](../known-errors.md#ke-18)).

Related: [Proxmox host](../proxmox-host.md), [vm100](../../nodes/vm100.md).
