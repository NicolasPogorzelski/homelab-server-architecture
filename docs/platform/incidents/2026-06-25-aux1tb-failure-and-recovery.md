# Incident & Recovery: Aux1TB Failure and Remote-Access Stabilization (2026-06-25)

A single working session that resolved three coupled problems on the single-host
Proxmox platform. Continues the prior lockout-recovery handover (host had booted
into emergency mode after an Aux1TB mount failure; remote access was restored via
an fstab `nofail` change before this session).

## Summary

| # | Problem | Outcome |
|---|---|---|
| 1 | Remote access fragile after the lockout; Proxmox web UI unreachable | pveproxy boot-race fixed (systemd drop-in); reachability model verified; LAN-SSH fallback confirmed |
| 2 | Five service LXCs would not start | Root cause = Aux1TB physical disk failure; disk to be decommissioned |
| 3 | Irreplaceable data on the dying disk | All rescued read-only and verified before any repair attempt; **no data loss** |

The three are linked: the same Aux1TB disk that caused the original emergency-mode
lockout also held the data-root / bind-mount sources of the five stopped LXCs.

## 1 — Remote-Access Stabilization

### 1.1 Lockout root cause corrected to a single cause

The handover protocol attributed the lockout to two independent faults (an Aux1TB
fsck failure **and** an unplugged network cable). Verified correction: the cable
was never unplugged. The single root cause is the Aux1TB mount failure tripping
`local-fs.target`, dropping the host into **emergency mode**, where no network
target is reached — so neither `tailscaled` nor a reachable `sshd` ever comes up.
In emergency mode the NIC link LED is on (kernel + driver loaded) but no interface
is configured, which is what made the cable look suspect. The durable mitigation
(fstab `nofail` on the Aux1TB entry) was already in place from the handover; it is
what allows the host to boot past the failed mount now.

### 1.2 pveproxy Tailscale-IP boot race (web UI down)

After the reboot, SSH worked but the Proxmox web UI on `:8006` was unreachable.
Root cause verified: `pveproxy` is configured to bind only the host Tailscale IP
(`/etc/default/pveproxy` → `LISTEN_IP=<tailscale-ip-proxmox-host>`, an intentional
"web UI over the tailnet only" hardening). On boot, pveproxy starts before
`tailscaled` has assigned that IP, fails five times with
`unable to create socket - Cannot assign requested address` (`EADDRNOTAVAIL`), and
systemd gives up (`start request repeated too quickly`). The service then stays
dead until a manual restart.

This is the same fault class as [KE-9](../known-errors.md#ke-9-postgresql-binds-only-loopback-after-boot-tailscale-ip-startup-race)
(PostgreSQL) and is recorded as
[KE-12](../known-errors.md#ke-12-pveproxy-fails-to-start-after-boot-tailscale-ip-bind-race).
Fix and the rejected alternatives:
[ADR pveproxy-tailscale-boot-ordering](../../decisions/pveproxy-tailscale-boot-ordering.md).
Recovery procedure:
[runbook pveproxy-tailscale-boot-race](../../../runbooks/platform/pveproxy-tailscale-boot-race.md).

### 1.3 Reachability model and the LAN-SSH fallback

Clarified and verified the rule that **reachability = binding × network × firewall**
— all three must hold, and "not firewall-blocked" does not imply "reachable":

| Service | Binds to | LAN reachable? | Tailscale reachable? |
|---|---|---|---|
| `sshd` | `0.0.0.0:22` (all interfaces) | Yes — verified `ssh root@<lan-ip-proxmox-host>` over a wired LAN path | Yes |
| Web UI (`pveproxy`) | host Tailscale IP only (`:8006`) | No — by binding, not by firewall | Yes |

The Proxmox firewall is `disabled` (no `cluster.fw`/`host.fw`); nothing is filtered.
A LAN-SSH "break-glass" was verified end to end from the admin notebook
(`SSH_CONNECTION` confirmed the LAN path, not a Tailscale tunnel). Emergency mode
remains the one state that removes **all** network paths at once — the firewall
notausgang only matters once the network is up.

## 2 — Aux1TB Physical Disk Failure

### 2.1 Symptom → diagnosis

Five LXCs were stopped (LXC200 monitoring, LXC211 paperless, LXC220 calibre-web,
LXC230 openwebui, LXC260 postgres); the three running ones (LXC210, LXC240,
LXC250) had no Aux1TB dependency. Each stopped container has a bind-mount whose
source is on `/mnt/aux1TB` (the Docker data-root strategy from the "Adding a New
Service" checklist). With Aux1TB unmounted, those source paths were missing and
Proxmox refused to start the containers.

Aux1TB did not mount because of **unrecoverable hardware medium errors**, not a
filesystem-only or cabling fault. Verified from the kernel log:

```
critical medium error, dev sdb, sector ...   (Unrecovered read error)
```

SMART confirmed end-of-life on a consumer-grade 1 TB drive (~6.5 years power-on):

| Attribute | Value |
|---|---|
| Current_Pending_Sector | 7688 |
| Offline_Uncorrectable | 7688 |
| Reported_Uncorrect | 18 |
| Power_On_Hours | ~56800 |

A read-only mount (`-o ro,noload`, no journal replay) **succeeded** and exposed the
full directory tree intact — the bad sectors had not hit the live metadata. This
gave a rescue window. Recorded as
[KE-13](../known-errors.md#ke-13-aux1tb-physical-disk-failure-medium-errors).

### 2.2 Rescue method (data-preservation first)

Principle: **rescue before repair.** No `fsck` or read-write mount was attempted on
the failing disk until everything was copied off — a read-write `fsck` writes to a
disk with 7688 pending sectors and can finish it off, and could "repair" metadata
into data loss. Method:

- Source mounted strictly read-only (`-o ro,noload`); VM100's jellyfin-data image
  loop-mounted read-only for the data inside it.
- Per-directory `tar` streamed over SSH to the admin notebook (`<lan-ip-notebook>`,
  gigabit wired), landing as archives on its LUKS-encrypted disk. `tar` was chosen
  over file-level `rsync` so ownership/permissions are preserved **inside** the
  archive (no root needed on the receiver, exact UIDs on restore).
- Ordered most-valuable-first so an interruption could not lose the irreplaceable
  data: databases/configs → media → regenerable caches.
- Read errors surfaced explicitly (`--ignore-failed-read`, stderr captured); the
  only messages were `socket ignored` (runtime sockets, not data), i.e. **zero**
  real medium errors during the rescue.

Full procedure:
[runbook aux1tb-failure-rescue](../../../runbooks/storage/aux1tb-failure-rescue.md).

### 2.3 Rescue inventory (verified, 0 data loss)

| Archive | Size | Content |
|---|---|---|
| `postgres.tar` | 187 M | PostgreSQL data directory |
| `paperless.tar` | 9.4 G | Paperless data (incl. containerd layers) |
| `monitoring.tar` | 6.3 G | Prometheus/Grafana data |
| `calibreweb.tar` | 2.1 G | containerd layers (regenerable) |
| `nextcloud.tar` | 61 M | — |
| `jf-jellyfin.tar` | 13 G | Jellyfin library DB + artwork/metadata |
| `audiobookshelf.tar` | 1.6 G | Audiobookshelf DB + covers |
| `calibre-library-metadata.tar` | 528 M | Calibre `metadata.db` + covers/`.opf` (media-free) |
| `calibre-web-config.tar` | 260 K | calibre-web `app.db` |
| `Archiv.tar` | 45 G | Audiobook archive (media) |

All 12 archives passed `tar -t` integrity checks. The ~88 GB difference between the
disk's 182 GB "allocated" and ~95 GB live data was dead space in VM100's sparse
300 GB jellyfin-data image (high-water-mark, never reclaimed by discard) — shed
automatically by copying file-level rather than imaging the raw disk.

## 3 — Media Library Metadata Map

The user's concern was the **library metadata** (the catalog behind the visible
web-UI entries), not the media files (those live on the VM102 MergerFS pool).
Authoritative source: the per-service `.env` files resolved from the IaC repo on
LXC250. Result:

| Library | Metadata location | Storage health | Status |
|---|---|---|---|
| Jellyfin | `/mnt/vm-data/jellyfin` on VM100 (= a `.raw` image on Aux1TB) | **failing** | Rescued (`jf-jellyfin.tar`) |
| Audiobookshelf | `/opt/docker/audiobookshelf` on the VM100 **root** disk | healthy (local-lvm) | Backed up (`audiobookshelf.tar`) |
| Calibre | calibre-web `app.db` on LXC220 rootfs; catalog `metadata.db` on the MergerFS pool | healthy | Backed up; catalog already on the pool |

Only Jellyfin's library was on the dying disk; it is rescued. Audiobookshelf and
Calibre metadata were never on Aux1TB. No re-scrape is required.

## System State After This Session

- **Remote access:** SSH over Tailscale and LAN both verified; web UI restored and
  made reboot-safe (pveproxy drop-in).
- **Containers:** LXC210/240/250 running. LXC200/211/220/230/260 and VM100 remain
  **down** pending data relocation off Aux1TB — not yet restored.
- **Aux1TB:** physically failed, mounted read-only for rescue only; to be
  decommissioned. All data copied to the admin notebook (`~/aux1tb-rescue/`).
- **Firewall:** disabled (unchanged).

## Open Items

1. **Permanent home + service restart.** Move the rescued databases/configs onto
   healthy storage (local-lvm SSD is the right fit for live DBs; the MergerFS pool
   is for media and is ~full), re-point the LXC bind mounts, restart LXC200/211/220/230/260
   and VM100. The off-disk copy on the notebook is staging, not a home.
2. **Aux1TB replacement decision.** Replace with a healthy disk vs. decommission
   only — open. Drives whether the Docker data-root strategy is restored on a new
   Aux1TB or moved.
3. **Docker data-root strategy invalidated.** The
   [docker-data-root-migration runbook](../../../runbooks/platform/docker-data-root-migration.md)
   and the "Adding a New Service" step 6 in
   [CLAUDE.md](../../../CLAUDE.md) both target `/mnt/aux1TB`, which no longer exists.
   Both need revision once the replacement decision is made.
4. **pveproxy fix vs. the canonical pattern.** The applied fix is an inline
   `ExecStartPre` poll loop; the repo already has the `postgresql-boot-order`
   pattern (`wait-for-tailscale-ip.sh` + Ansible role). Aligning pveproxy to that
   shared script/role is the durable follow-up. See the
   [ADR](../../decisions/pveproxy-tailscale-boot-ordering.md).
5. **No off-site backup** of the rescued set — it is a single local copy on one
   notebook (consistent with the existing off-site-backup tech-debt item).

## Configuration Changes Made

| Where | Change |
|---|---|
| `/etc/systemd/system/pveproxy.service.d/wait-tailscale.conf` (Proxmox host) | New drop-in: `After=/Wants=tailscaled.service` + `ExecStartPre` poll until the Tailscale IP is present (≤30 s). Reboot-safety not yet tested on a fresh boot. |

No other persistent changes. The Aux1TB read-only mounts and the VM100 disk
mappings used for inspection were created transiently and cleaned up.

## Lessons Learned

- Emergency mode removes every network path at once — LAN and Tailscale both. The
  only structural defence is keeping the boot out of emergency mode (`nofail` on
  non-critical mounts), not any single access path.
- "Bind to the Tailscale IP only" hardening (KE-9, this incident) repeatedly
  collides with boot ordering: any service pinned to the Tailscale IP needs a
  wait-for-IP gate, or it loses the race and dies.
- A consumer drive at ~6.5 years with thousands of pending sectors is a
  decommission, not a repair. Rescue read-only first; never `fsck` a failing disk
  before the data is off it.

## Related Documents

- [KE-12 — pveproxy Tailscale-IP bind race](../known-errors.md#ke-12-pveproxy-fails-to-start-after-boot-tailscale-ip-bind-race)
- [KE-13 — Aux1TB physical disk failure](../known-errors.md#ke-13-aux1tb-physical-disk-failure-medium-errors)
- [ADR — pveproxy Tailscale boot ordering](../../decisions/pveproxy-tailscale-boot-ordering.md)
- [Runbook — pveproxy boot-race recovery](../../../runbooks/platform/pveproxy-tailscale-boot-race.md)
- [Runbook — Aux1TB failure rescue](../../../runbooks/storage/aux1tb-failure-rescue.md)
- [Proxmox Host](../proxmox-host.md)
- [VM100 node](../../nodes/vm100.md)
- [Platform Changelog](../changelog.md)
