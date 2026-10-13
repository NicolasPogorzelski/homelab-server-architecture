# Media Over the Tailnet: Withdrawing the LAN Exception

## Status

Decided and applied 2026-10-01, recorded 2026-10-13. Supersedes
[DD#8](design-decisions.md#dd-8) for every service it named. The media services left the LAN on
2026-10-01; Nextcloud, which DD#8 still listed, left it the same day without anybody deciding so,
when `lan_guard` began dropping new inbound LAN connections on every node.

## Context

DD#8 kept Jellyfin, Audiobookshelf and Nextcloud reachable on the LAN as a performance exception.
Its premise was that traffic through the overlay is limited by the internet uplink, about
50 Mbit/s, which would make high-bitrate streaming at home unusable.

That premise describes a relayed connection, and two nodes on the same LAN do not relay. Measured
2026-10-01: `tailscale ping` between them answered in 1 ms over the LAN address, and an SMB transfer
over the tailnet reached 94.9 MB/s up and 104.9 MB/s down. On 1 GbE the link and `tailscaled` set the
ceiling, not the uplink; vm102's `tailscaled` used most of one core at that rate. The uplink still
limits streaming from outside the home, which is a property of the uplink and not of the overlay.

## Decision

No service is reachable on the LAN. Clients at home join the tailnet like clients anywhere else.

- Jellyfin binds vm100's Tailscale address. It sat on loopback behind `tailscale serve --tcp`
  from 2026-10-01 to 2026-10-07, where streams stalled inside the forwarder
  ([KE-28](../platform/known-errors.md#ke-28)); a direct bind avoids the forwarder entirely.
- Audiobookshelf publishes on loopback behind `tailscale serve`. Audio needs a fraction of the
  bandwidth that stalled Jellyfin, and no stall has been reported for it.
- The streaming box at the TV is a tailnet device with its own tag, `tag:media-player`, granted
  Jellyfin's port and nothing else ([ACL Rule 14](../platform/tailscale-acl.md#rule-14---media-player-the-streaming-box-at-the-tv)).
- vm100's LAN interface accepts no IPv6 router advertisements, so wildcard listeners have no global
  IPv6 address to answer on (`netplan_no_ra` role).
- `lan_guard` drops new inbound LAN connections on every node, with recorded exceptions for SMB to
  vm102 and break-glass SSH to the hypervisor. A service that still binds the wildcard - Apache on
  lxc210 - is closed to the LAN by this layer, not by its own configuration.

## Consequences

- A device that cannot run Tailscale cannot stream at home. Two LAN clients in Jellyfin's activity
  log were never identified; they join the tailnet when they are next needed, or stay without
  access.
- When Tailscale is down on vm100 or on the client, media is down at home as well. The LAN no
  longer serves as a fallback, which is the point of withdrawing it.
- Throughput rests on a direct connection. If two devices fall back to a DERP relay, streams are
  capped by the uplink again. `tailscale ping` names the path when a stream is slow.
- Three concurrent 4K streams over the tailnet have not been measured.
- Nextcloud is closed to the LAN by `lan_guard` while Apache still binds `*:80` and `*:443`. Moving
  it behind `tailscale serve` belongs to its Debian 13 upgrade and closes the bind as well.

## Verification

```bash
# On vm100: Jellyfin on the Tailscale address, Audiobookshelf on loopback, no global IPv6 on the LAN
ss -Hltn sport = :8096 or sport = :13378
ip -6 -o addr show dev enp6s18 scope global    # prints nothing

# On vm100 and lxc210: the LAN drop rule is loaded and counting
nft list table inet lan_guard | grep drop
```

Measured 2026-10-13: Jellyfin on the Tailscale address, Audiobookshelf on `127.0.0.1:13378` with its
serve forward on `tailscale0`, no global IPv6 on `enp6s18`, and the `lan_guard` drop rule loaded on
vm100 and lxc210 with several thousand dropped packets each since boot.

## Related Documents

- [DD#8 - LAN Exposure for Performance-Critical Workloads](design-decisions.md#dd-8) (superseded)
- [vm100 - No Media Ports on the LAN](../nodes/vm100.md#no-media-ports-on-the-lan)
- [KE-28 - Jellyfin streams stalled inside the serve forwarder](../platform/known-errors.md#ke-28)
- [Tailscale ACL model](../platform/tailscale-acl.md)
- [SMB bind and LAN access](smb-bind-and-lan-access.md) (the storage path, which still crosses the LAN)
