# SMB on vm102: Wildcard Bind, Kernel Filter, and the LAN Mount Exception

## Status
Implemented 2026-07-14 (steps 1a and 1b below). Step 2, moving the LAN mounts to the tailnet, is
replaced by the storage network item in the [remediation plan](../platform/remediation-plan.md#storage-network).
Supersedes / superseded by: -.

## Context
The binding rule says a service binds its Tailscale address, or loopback behind `tailscale serve`,
never a LAN interface. Samba on vm102 does not: `smb.conf` sets `bind interfaces only = no`, and
access control rested on `hosts allow` / `hosts deny`, which Samba evaluates after accepting the TCP
connection. Measured 2026-07-14:

```
$ ss -tlnp | grep 445
LISTEN 0 50   0.0.0.0:445   0.0.0.0:*   users:(("smbd",pid=654,...))
LISTEN 0 50      [::]:445      [::]:*   users:(("smbd",pid=654,...))

$ testparm -s        # effective configuration, before step 1a
hosts allow = 127.0.0.1 <tailscale-cgnat-range> <lan-ip-vm100> <lan-ip-proxmox> <lan-ip-device3>
hosts deny  = 0.0.0.0/0
```

vm102's LAN interface carries a globally routable IPv6 address, so 445 was bound on a world-routable
address, kept unreachable only by the router's default and the lack of an IPv6 `hosts allow` entry.

Who used the LAN path, from `smbstatus -b` and the per-client logs (`log file = /var/log/samba/%m.log`):

| `hosts allow` entry | Node | Connects as | Use |
|---|---|---|---|
| `<lan-ip-vm100>` | vm100 | `media-jf`, `media-abs` | active |
| `<lan-ip-proxmox>` | Proxmox host | `books-svc`, `openwebui`, `paperless`, `nextcloud` | active |
| `<lan-ip-device3>` | admin desktop | - | no session; client log empty since 2026-06-17 |

Measured 2026-09-26: the host mounts eight shares, six over vm102's LAN address and two
(`postgres-backups`, `db-backups`) over its Tailscale address; vm100 mounts four, one per library,
over the LAN address. One of the host's six LAN mounts was removed on 2026-10-10 with the service it
served ([decommission](vaultwarden-decommission.md)). The admin workstations mount over the
Tailscale address.

### Is the tailnet slower?
Two nodes on one subnet use a direct WireGuard path: `tailscale ping storage` answered
`via <lan-ip-vm102>:41641 in 2ms`. Workstation to vm102, 1500 MiB of zeroes into a discarding sink
(network and crypto, no disk):

| Path | Throughput |
|---|---|
| LAN address, unencrypted | 809 Mbit/s (101 MiB/s) |
| Tailscale address, WireGuard | 741 Mbit/s (93 MiB/s) |

Both are at the practical ceiling of the gigabit link; WireGuard costs about 8 %.

### The explicit bind does not work here
Samba does not bind an IPv4 address on `tailscale0`. The interface is a point-to-point TUN device
(`<POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP>`, no `BROADCAST`, which `ens18` carries), and Samba's
IPv4 interface selection skips it. Tried on 2026-07-14 with `bind interfaces only = yes`, each with a
restart and a socket check:

| `interfaces = ...` | Result |
|---|---|
| `lo <lan-ip-vm102>/24 <tailscale-ip-vm102>/32 <tailscale-ip6-vm102>/128` | LAN, loopback and Tailscale IPv6 bound; Tailscale IPv4 not bound |
| `lo <lan-ip-vm102>/24 tailscale0` | `tailscale0` ignored, no Tailscale address bound |
| `lo <lan-ip-vm102>/24 <tailscale-ip-vm102>` | no Tailscale address bound |

IPv6 has no broadcast, so the rejecting check never applies. From a client, Tailscale 445 was
refused while the LAN address answered. The change was rolled back (both paths reachable, six
sessions intact).

## Options
- **Explicit bind in Samba.** Lost: measured above, it cuts the tailnet path it was meant to keep.
- **Keep `hosts allow` as the only control.** Lost: an application filter after the TCP accept, on a
  socket bound to a routable IPv6 address.
- **Move every LAN mount to the Tailscale address at once.** Lost for this change: it couples each
  mount to `tailscaled` at boot, the fault class of [KE-15](../platform/known-errors.md#ke-15).
- **Wildcard bind, boundary enforced by an nftables table on vm102.** Chosen.

## Decision
- **Step 1a (2026-07-14).** `<lan-ip-device3>` is removed from `hosts allow`. The admin desktop
  keeps SMB over the tailnet through
  [ACL Rule 7](../platform/tailscale-acl.md#rule-7---admin-workstations) (`tag:storage:445`).
- **Step 1b (2026-07-14).** An nftables table `inet smb_guard` on vm102's LAN interface `ens18`
  drops all inbound TCP/445 over IPv6 and admits IPv4 445 only from `<lan-ip-vm100>` and
  `<lan-ip-proxmox>`; `tailscale0` is not evaluated. Its own oneshot unit loads it, never
  `nftables.service`, whose stock configuration and stop action flush the whole ruleset, Tailscale's
  `ts-input` and `ts-forward` chains included. Sources: `snippets/storage/smb-guard.nft`,
  `snippets/systemd/smb-guard.service`. Rollback: `nft delete table inet smb_guard`.

Result, measured 2026-07-14 and across a reboot of vm102: 99 packets accepted from vm100 and the
host, 3 dropped (a deliberate probe from the workstation's LAN address), 0 on the IPv6 rule;
Tailscale's chains unchanged; after the reboot the unit loaded the table and every CIFS mount and SMB
session came back; from the workstation Tailscale 445 answered and LAN 445 was refused.

### Relation to `lan_guard`
Since 2026-10-01 `lan_guard` drops new inbound LAN connections on every node. On vm102 its only
exception is TCP/445 from the hypervisor and vm100 (`lan_guard_allow` in
`ansible/inventory/host_vars/vm102.yml`), the same pair `smb_guard` admits. Both tables drop what
they do not accept, so a LAN SMB path has to be open in each; IPv6 445 is dropped by both.
`smb_guard` is the second layer and hand-deployed; it is adopted into the `nft_guard` role
in the storage network window. `hosts allow` stays underneath as a third.

## Consequences
- `smbd` keeps listening on `0.0.0.0:445` and `[::]:445`; the kernel is the enforcement point.
- With a wildcard bind `smbd` does not wait for `tailscaled` at boot and picks up `tailscale0` when
  it appears, so it carries no `After=tailscaled.service` drop-in.
- LAN mounts are still admitted by source address, which DHCP can change and a LAN host can spoof.
  The storage network item replaces step 2: a host-only bridge for the host, vm100 and vm102, then
  `smb_guard` drops 445 on `ens18` entirely and the `lan_guard` exception goes. Samba keeps its
  wildcard bind there too, because an explicit bind would cut the workstations' tailnet path.
- If the tailnet is down the workstations lose SMB; the Proxmox console still reaches vm102.

## Verification
```bash
# on vm102
nft list table inet smb_guard                # rules and counters
nft list table inet lan_guard | grep 445     # the same two sources
smbstatus -b                                 # sessions from vm100 and the Proxmox host
# from an admin workstation
ncat -z -w3 <tailscale-ip-vm102> 445         # open
ncat -z -w3 <lan-ip-vm102> 445               # refused or timeout
# on the host and vm100, after a reboot of vm102
findmnt -t cifs -o TARGET,SOURCE             # every mount back
```

## Related Documents
- [Samba](../platform/samba.md)
- [Tailscale ACL model](../platform/tailscale-acl.md)
- [Media over the tailnet](media-over-the-tailnet.md)
- [KE-15](../platform/known-errors.md#ke-15)
- Reference configuration: `snippets/storage/smb.conf.storage-vm102.sanitized.conf`
