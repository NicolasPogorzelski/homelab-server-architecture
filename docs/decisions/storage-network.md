# SMB to vm102 Over a Host-Only Bridge

## Status
Accepted 2026-11-18. Replaces step 2 of
[`smb-bind-and-lan-access.md`](smb-bind-and-lan-access.md). Supersedes / superseded by: -.

## Context
Every SMB client of vm102 runs on this one hypervisor: the host's seven service-share mounts and
vm100's five media and archive mounts. Two paths carry that traffic today.

- Four host mounts and all five vm100 mounts reach vm102's LAN address. The LAN is one flat
  segment shared with the household's devices and the streaming box. `smb_guard` and `lan_guard`
  admit TCP/445 by source address only, so a LAN device that takes over vm100's or the host's
  address passes both.
- Three host mounts, the guest-backup and database-backup targets, reach vm102 over the tailnet
  ([Rule 4](../platform/tailscale-acl.md#rule-4---hypervisor-smb-from-vm102)). The backups
  therefore depend on `tailscaled` on the host being up, which at boot it is not
  ([KE-18](../platform/known-errors.md#ke-18)).

Verified 2026-11-18: the host has one bridge, `vmbr0` on `nic0`, under ifupdown2; vm100 and vm102
each have one network device, `net0` on `vmbr0`; four of the host's CIFS mounts and all five of
vm100's use vm102's LAN address, by `/etc/network/interfaces`, `qm config` and `findmnt -t cifs`.

Verified 2026-10-01: SMB over Tailscale from the admin desktop reached 94.9 MB/s up and 104.9 MB/s
down with `smbclient`; neither of vm102's two vCPUs saturated.

## Options
- **Keep the LAN path.** No work; the protection stays a source-address filter on a shared segment.
- **A VLAN for storage.** Separates the segment, but needs a switch and router that tag VLANs;
  new hardware.
- **All SMB over the tailnet.** One encrypted path, but every mount, the backups included, then
  depends on `tailscaled` at boot, and the WireGuard tunnel costs CPU on vm102 for traffic that
  never leaves the host.
- **A host-only bridge.** `vmbr1` without `bridge-ports` exists only inside the hypervisor; no
  device on the LAN or the tailnet can send to it.

## Decision
A host-only bridge carries all SMB between the hypervisor, vm100 and vm102.

1. `vmbr1` on the host, no `bridge-ports`, a static address from a /29 of RFC 1918 space that is
   not used on the LAN; the addresses are recorded in the inventory.
2. `net1` on `vmbr1` for vm102 and vm100, each with a static address and no gateway, so no default
   route moves.
3. `smb_guard` and `hosts allow` admit the bridge addresses; Samba keeps its wildcard bind, because
   an explicit bind cuts the tailnet path the admin workstations use.
4. The mounts move one at a time, the host's first and the three backup targets among them, then
   vm100's. Each mount uses `x-systemd.automount` and is tested by unmounting it and reading through
   the automount; each client is rebooted once, after its last move.
5. After the last move: `smb_guard` drops 445 on `ens18`, the `lan_guard` exception for 445 on
   vm102 goes, ACL Rule 4 goes, and the hand-deployed `smb_guard` table is adopted into the
   `nft_guard` role.

The admin workstations keep SMB over the tailnet through Rule 7.

## Consequences
- No LAN device reaches vm102 on 445, and the backups no longer wait for `tailscaled`.
- The bridge has no DHCP and no DNS; mounts name the address, as the LAN mounts do.
- The host's reboot stops every guest, and vm100's stops the media services; both need a window
  without streams and before the nightly shutdown.
- A wrong `net1` setting can take a VM's default route; step 2 sets no gateway, and the VM console
  in the Proxmox interface stays the recovery path.
- Restoring the host from the guest backups now also needs `vmbr1`; the platform restore runbook
  gains that step.
