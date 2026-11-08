# The Streaming Box Reaches Jellyfin Over the LAN

## Status
Implemented 2026-11-08. Supersedes, for the streaming box only, the rule "no service is reachable
on the LAN" in [Media over the tailnet](media-over-the-tailnet.md). Superseded by: -.

## Context
Since 2026-10-01 every media client reaches Jellyfin over the tailnet. The streaming box at the TV
is an Android TV device; its Tailscale app runs WireGuard in userspace on the device's CPU.

On 2026-11-08 playback on the box stalled. The scrub and the loose plug of
[KE-33](../platform/known-errors.md#ke-33) were ruled out: no scrub ran, and the box held a
gigabit link. What remained was the Tailscale path ([KE-34](../platform/known-errors.md#ke-34)):

Verified 2026-11-08: about 20 path changes to the box between 17:39 and 17:56, during playback with
Ethernet only, between the LAN endpoint, the router's public address and a DERP relay, by
`journalctl -u tailscaled | grep "now using"` on vm100.

Verified 2026-11-08: saturated with HTTP downloads from Jellyfin over the tailnet, the box's tunnel
carried 205-229 Mbit/s at about 70 % CPU on all four cores, by `/proc/net/dev` (`tun0`) and
`/proc/stat` sampled each second on the box. The highest-bitrate file in the library averages
121.8 Mbit/s, which leaves the tunnel under twice that rate for bitrate peaks.

Verified 2026-11-08: 967 Mbit/s from vm100 to the box over the LAN, by `nc` into a listener on the
box for 40 s, and no loss in 300 pings from the hypervisor during that run. Playback over the LAN
then ran 29 minutes without a stall or a player buffer event (`logcat` on the box), at 24 % CPU,
with no byte through its `tun0`.

The cause of the path changes is not found. Ten minutes of synthetic load over the tunnel produced
none.

## Options
- **Keep the box on the tailnet until the cause is found.** The stalls would continue for an
  unknown time, and the tunnel's CPU cost on the box stays whatever the cause turns out to be.
- **Open Jellyfin to the whole LAN, as DD-8 did.** Every device at home would reach it, phones and
  TVs included, for a problem only one device has.
- **The LAN for the streaming box alone.** Chosen.

## Decision
Jellyfin publishes on vm100's LAN address as well as its Tailscale address. On vm100, `lan_guard`
admits TCP 8096 from the streaming box's LAN address and from nothing else, and `listener_metrics`
allows 8096 on record. The box's Jellyfin client points at vm100's LAN address. Every other client
and service stays tailnet-only, and the box keeps its tag and ACL rule.

## Consequences
- The path trusts a source address on a flat LAN. A device at home that takes over the box's
  address reaches Jellyfin. The home network has no segmentation
  ([DD-9](design-decisions.md#dd-9)).
- Jellyfin speaks HTTP without TLS on this path. Login and token of the box's Jellyfin user can be
  read by a device that intercepts LAN traffic.
- The box needs a fixed DHCP reservation. Without it, the box gets another address, `lan_guard`
  drops its connections, and playback fails until the reservation is restored.
- The client is bound to vm100's LAN address. If that address changes, the client is repointed.
- Revisit when KE-34's cause is found: with a stable tunnel, the exception goes.

## Verification
```bash
# On vm100: Jellyfin on the Tailscale and the LAN address, the exception loaded and counting
ss -Hltn sport = :8096
nft list table inet lan_guard | grep 8096
```

The Jellyfin dashboard shows the box's session arriving from `<lan-ip-streaming-box>`.

## Related Documents
- [Media over the tailnet](media-over-the-tailnet.md)
- [KE-33](../platform/known-errors.md#ke-33), [KE-34](../platform/known-errors.md#ke-34)
- [Jellyfin](../services/jellyfin.md), [vm100](../nodes/vm100.md)
- [Tailscale ACL, Rule 14](../platform/tailscale-acl.md#rule-14---media-player-the-streaming-box-at-the-tv)
