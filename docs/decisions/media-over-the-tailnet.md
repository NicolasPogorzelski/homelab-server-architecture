# Media Clients Use the Tailnet; No Service Is Reachable on the LAN

## Status
Implemented 2026-10-01. Recorded 2026-10-13. Supersedes [DD-8](design-decisions.md#dd-8) and the
LAN-exposure part of [DD-9](design-decisions.md#dd-9). Superseded by: -.

Verified 2026-10-13: Jellyfin on vm100's Tailscale address, Audiobookshelf on `127.0.0.1:13378` with
its serve forward on `tailscale0`, no global IPv6 address on `enp6s18`, and the `lan_guard` drop
rule loaded on vm100 and lxc210 with several thousand dropped packets each since boot.

## Context
DD-8 kept Jellyfin, Audiobookshelf and Nextcloud reachable on the LAN as a performance exception,
on the premise that overlay traffic is capped by the internet uplink (about 50 Mbit/s).

That premise describes a relayed connection. Two nodes on the same LAN connect directly. Measured
2026-10-01: `tailscale ping` between them answered in 1 ms over the LAN address, and an SMB transfer
over the tailnet reached 94.9 MB/s up and 104.9 MB/s down. On 1 GbE the link and `tailscaled` set
the ceiling; vm102's `tailscaled` used most of one core at that rate. The uplink limits streaming
from outside the home only.

## Options
- **Keep the LAN exception.** Its performance argument does not survive the measurement, and
  it leaves wildcard listeners answering every device on the home network.
- **All clients on the tailnet, the LAN closed on every node.** Chosen.

## Decision
No service is reachable on the LAN. Clients at home join the tailnet like clients anywhere else.

- Jellyfin binds vm100's Tailscale address. Behind `tailscale serve --tcp` (2026-10-01 to
  2026-10-07) streams stalled inside the forwarder ([KE-28](../platform/known-errors.md#ke-28)); a
  direct bind leaves TCP to the kernel.
- Audiobookshelf binds loopback behind `tailscale serve`. Audio needs a fraction of Jellyfin's
  bandwidth, and no stall has been reported.
- The streaming box at the TV is a tailnet device with `tag:media-player`, granted Jellyfin's port
  and nothing else
  ([ACL Rule 14](../platform/tailscale-acl.md#rule-14---media-player-the-streaming-box-at-the-tv)).
- vm100's LAN interface accepts no IPv6 router advertisements (`netplan_no_ra`), so wildcard
  listeners have no global IPv6 address to answer on.
- `lan_guard` drops new inbound LAN connections on every node. Its only exceptions are SMB to vm102
  from vm100 and the hypervisor ([SMB bind](smb-bind-and-lan-access.md)), and break-glass SSH and
  netconsole to the hypervisor. Apache on lxc210 still binds the wildcard and is closed to the LAN
  by this layer, not by its own configuration.

## Consequences
- A device that cannot run Tailscale cannot stream at home. Two LAN clients in Jellyfin's activity
  log were never identified; they join the tailnet when next needed or stay without access.
- When Tailscale is down on vm100 or on the client, media is down at home as well. There is no LAN
  fallback.
- Throughput depends on a direct connection. If two devices fall back to a DERP relay, streams are
  capped by the uplink; `tailscale ping` shows the path when a stream is slow.
- Three concurrent 4K streams over the tailnet have not been measured.
- Moving Nextcloud behind `tailscale serve` closes Apache's wildcard bind as well; it is open work in
  the [remediation plan](../platform/remediation-plan.md).

## Verification
```bash
# On vm100: Jellyfin on the Tailscale address, Audiobookshelf on loopback, no global IPv6 on the LAN
ss -Hltn sport = :8096 or sport = :13378
ip -6 -o addr show dev enp6s18 scope global    # prints nothing

# On vm100 and lxc210: the LAN drop rule is loaded and counting
nft list table inet lan_guard | grep drop
```

## Related Documents
- [DD-8: LAN exposure for performance-critical workloads](design-decisions.md#dd-8) (superseded)
- [vm100: no media ports on the LAN](../nodes/vm100.md#no-media-ports-on-the-lan)
- [KE-28](../platform/known-errors.md#ke-28)
- [Tailscale ACL model](../platform/tailscale-acl.md)
- [SMB bind and LAN access](smb-bind-and-lan-access.md) (the storage path, which still crosses the LAN)
