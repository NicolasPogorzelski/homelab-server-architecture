# SMB on VM102: Interface Binding and the LAN Access Exception

## Context

The platform binding rule says services bind to the Tailscale IP, or to loopback behind
`tailscale serve` — never to LAN interfaces. Samba on VM102 has never followed it.

`smb.conf` sets `bind interfaces only = no`, so `smbd` accepts on every interface. Access
control rests entirely on `hosts allow` / `hosts deny`, which Samba evaluates **after** the TCP
connection is accepted, inside the application. That is a filter, not a bind: the socket is open
to anyone who can route a packet to it, and the rule set decides afterwards whether to answer.

Verified on the live node (2026-07-14, read-only):

```
$ ss -tlnp | grep 445
LISTEN 0 50   0.0.0.0:445   0.0.0.0:*   users:(("smbd",pid=654,...))
LISTEN 0 50      [::]:445      [::]:*   users:(("smbd",pid=654,...))

$ testparm -s        # effective config, not the file
hosts allow = 127.0.0.1 <tailscale-cgnat-range> <lan-ip-vm100> <lan-ip-proxmox> <lan-ip-device3>
hosts deny  = 0.0.0.0/0
```

VM102's LAN interface carries a **globally routable IPv6 address**, and `smbd` listens on
`[::]:445`. Port 445 is therefore bound on a world-routable address. Two things prevent exposure
today: the router blocks inbound IPv6 by default, and `hosts allow` contains no IPv6 entry, so
Samba would reject the session anyway. Both are real, but neither is the service binding
correctly — the platform's guarantee currently lives in a consumer router's default setting.

`docs/platform/samba.md` claimed "No public exposure" and "Access restricted to LAN and Tailscale
overlay". The first half was an unverified assertion and is corrected by this decision.

## Who actually uses the LAN path

Established from live SMB sessions (`smbstatus -b`) and the per-client logs
(`log file = /var/log/samba/%m.log` writes one file per connecting machine), not from the config:

| `hosts allow` entry | Node | Connects as | Status |
|---|---|---|---|
| `<lan-ip-vm100>` | VM100 | `media-jf`, `media-abs` | active, load-bearing |
| `<lan-ip-proxmox>` | Proxmox host | `books-svc`, `openwebui`, `paperless`, `nextcloud`, `vaultwarden` | active, load-bearing |
| `<lan-ip-device3>` | admin desktop | — | **no session; client log empty since 2026-06-17** |

The Proxmox host mounts five shares over the LAN IP and one — `postgres-backups` — over VM102's
Tailscale IP (changed 2026-06-12). VM100 mounts two over the LAN IP. That single Tailscale mount
is the existence proof that the transport works.

The admin workstations do **not** need the LAN entry: one already mounts over the Tailscale IP,
the other has not opened an SMB session in weeks. Both are tailnet members.

## Measurement: is Tailscale slow?

The standing objection to a Tailscale-only Samba was throughput — the assumption that tailnet
traffic is capped by the site's internet uplink. It is not: two nodes on the same subnet negotiate
a **direct** WireGuard path over the LAN, and the DERP relay is only a fallback when no direct
path can be established.

```
$ tailscale ping storage
pong from storage (<tailscale-ip-vm102>) via <lan-ip-vm102>:41641 in 2ms   # direct, over the LAN
```

Throughput, workstation → VM102, 1500 MiB of zeroes into a discarding sink (network + crypto only,
no disk):

| Path | Throughput |
|---|---|
| LAN address, unencrypted | 809 Mbit/s (101 MiB/s) |
| Tailscale address, WireGuard | 741 Mbit/s (93 MiB/s) |

Both are at the practical ceiling of the gigabit link. **Tailscale costs ~8 %, not an order of
magnitude.** The performance argument for keeping LAN mounts does not survive measurement.

## Decision

Split the change in two, because the two halves carry very different risk.

### Step 1 — bind explicitly, drop the dead LAN entry (this decision)

- `bind interfaces only = yes`
- `interfaces = 127.0.0.1 <tailscale-ip-vm102> <lan-ip-vm102>` — three explicit IPv4 addresses,
  which also removes the `[::]:445` listener and with it the world-routable socket.
- Remove `<lan-ip-device3>` from `hosts allow` (no traffic, no consumer).

No mount is touched. The LAN transport keeps working at full speed for VM100 and the Proxmox
host, so no service can break. The world-routable socket — the only part of this that does not
depend on a router default — closes immediately.

### Step 2 — migrate the mounts (deferred, separate change)

Move the seven CIFS mounts (five on the Proxmox host, two on VM100) from the LAN IP to VM102's
Tailscale IP, one at a time, each with automount and `x-systemd.mount-timeout`, each verified
across a reboot. Only when all seven survive a reboot does `<lan-ip-vm102>` leave `interfaces` and
the LAN entries leave `hosts allow`.

This is deliberately **not** bundled into step 1. A mount that depends on Tailscale can fail at
boot before `tailscaled` has connected — the KE-9 / KE-12 fault class, and precisely the mechanism
behind KE-15, where a silently failed mount left a bind pointing at an empty directory for a
month. Moving seven mounts into that dependency without automount and timeouts in place would
invite a second KE-15. KE-15 must be repaired first.

## Consequences

- Access control on the LAN path remains address-based (`hosts allow`) until step 2 completes.
  An IP is not an identity: it can change by DHCP, it can be spoofed on the LAN, and any device
  that acquires the address inherits the access. This is the residual risk step 2 removes.
- After step 1, `smbd` startup does **not** depend on `tailscaled`, because it still binds a LAN
  address that exists at boot. That coupling only arrives with step 2 and must be solved there
  (`After=tailscaled.service` plus a bind-retry, same pattern as `postgres_exporter`).
- Break-glass: with a Tailscale-only Samba (post step 2), a tailnet outage would also cut data
  access. The answer is not a permanently open LAN rule but the Proxmox console, which reaches
  VM102 independently of Tailscale and can re-add a `hosts allow` entry when genuinely needed.
- Before removing `<lan-ip-device3>`, confirm in the Tailscale admin console that the admin
  desktop's tag grants it port 445 on `tag:storage`. If it carries `tag:client` rather than
  `tag:admin`, removing the LAN entry would take away its last path — unused, but still a path.

## Verification

After step 1, on VM102:

```bash
testparm -s | grep -E 'bind interfaces|interfaces|hosts allow'
ss -tlnp | grep 445      # expect three IPv4 listeners, no [::]:445
smbstatus -b             # expect existing sessions from VM100 and the Proxmox host intact
```

On the Proxmox host and VM100, the existing mounts must still be present:

```bash
findmnt -t cifs -o TARGET,SOURCE
```

## References

- [Samba architecture](../platform/samba.md)
- [Tailscale ACL model](../platform/tailscale-acl.md)
- [Known errors: KE-15 (mount fault class)](../platform/known-errors.md#ke-15)
- [PostgreSQL Tailscale boot ordering](postgresql-tailscale-boot-ordering.md) — same coupling,
  solved once already
- Reference config: [smb.conf.storage-vm102.sanitized.conf](../../snippets/storage/smb.conf.storage-vm102.sanitized.conf)
