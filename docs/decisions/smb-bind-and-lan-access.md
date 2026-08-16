# SMB on VM102: Interface Binding and the LAN Access Exception

## Context

The platform binding rule says services bind to the Tailscale IP, or to loopback behind
`tailscale serve` - never to LAN interfaces. Samba on VM102 has never followed it.

`smb.conf` sets `bind interfaces only = no`, so `smbd` accepts on every interface. Access
control rests entirely on `hosts allow` / `hosts deny`, which Samba evaluates after the TCP
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

VM102's LAN interface carries a globally routable IPv6 address, and `smbd` listens on
`[::]:445`. Port 445 is therefore bound on a world-routable address. Two things prevent exposure
today: the router blocks inbound IPv6 by default, and `hosts allow` contains no IPv6 entry, so
Samba would reject the session anyway. Both are real, but neither is the service binding
correctly - the platform's guarantee currently lives in a consumer router's default setting.

`docs/platform/samba.md` claimed "No public exposure" and "Access restricted to LAN and Tailscale
overlay". The first half was an unverified assertion and is corrected by this decision.

## Who actually uses the LAN path

Established from live SMB sessions (`smbstatus -b`) and the per-client logs
(`log file = /var/log/samba/%m.log` writes one file per connecting machine), not from the config:

| `hosts allow` entry | Node | Connects as | Status |
|---|---|---|---|
| `<lan-ip-vm100>` | VM100 | `media-jf`, `media-abs` | active, load-bearing |
| `<lan-ip-proxmox>` | Proxmox host | `books-svc`, `openwebui`, `paperless`, `nextcloud`, `vaultwarden` | active, load-bearing |
| `<lan-ip-device3>` | admin desktop | - | **no session; client log empty since 2026-06-17** |

The Proxmox host mounts five shares over the LAN IP and one - `postgres-backups` - over VM102's
Tailscale IP (changed 2026-06-12). VM100 mounts two over the LAN IP. That single Tailscale mount
is the existence proof that the transport works.

The admin workstations do not need the LAN entry: one already mounts over the Tailscale IP,
the other has not opened an SMB session in weeks. Both are tailnet members.

## Measurement: is Tailscale slow?

The standing objection to a Tailscale-only Samba was throughput - the assumption that tailnet
traffic is capped by the site's internet uplink. It is not: two nodes on the same subnet negotiate
a direct WireGuard path over the LAN, and the DERP relay is only a fallback when no direct
path can be established.

```
$ tailscale ping storage
pong from storage (<tailscale-ip-vm102>) via <lan-ip-vm102>:41641 in 2ms   # direct, over the LAN
```

Throughput, workstation -> VM102, 1500 MiB of zeroes into a discarding sink (network + crypto only,
no disk):

| Path | Throughput |
|---|---|
| LAN address, unencrypted | 809 Mbit/s (101 MiB/s) |
| Tailscale address, WireGuard | 741 Mbit/s (93 MiB/s) |

Both are at the practical ceiling of the gigabit link. **Tailscale costs ~8 %, not an order of
magnitude.** The performance argument for keeping LAN mounts does not survive measurement.

## Attempted and rejected: explicit bind in Samba (2026-07-14)

The obvious remedy - `bind interfaces only = yes` plus an explicit `interfaces` list - **does not
work on this node**, and the reason is a property of Samba, not of the configuration.

**Samba does not bind IPv4 addresses on `tailscale0`.** The interface is a point-to-point TUN
device: `<POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP>` - note the absence of `BROADCAST`, which
`ens18` carries. Samba's IPv4 interface selection skips such interfaces. Three notations were
tried against the live node, each with a restart and a socket check:

| `interfaces = ...` | Result |
|---|---|
| `lo <lan-ip-vm102>/24 <tailscale-ip-vm102>/32 <tailscale-ip6-vm102>/128` | LAN + loopback + Tailscale IPv6 bound; Tailscale IPv4 not bound |
| `lo <lan-ip-vm102>/24 tailscale0` (interface name) | `tailscale0` ignored entirely - no Tailscale address bound at all |
| `lo <lan-ip-vm102>/24 <tailscale-ip-vm102>` (bare IP) | same - no Tailscale address bound |

IPv6 succeeds where IPv4 fails because IPv6 has no broadcast concept, so the check that rejects
the interface never applies. There is no notation that binds the Tailscale IPv4 address.

Confirmed from the client side: with the explicit bind active, `ncat -z <tailscale-ip-vm102> 445`
was refused while the LAN address answered. **An explicit bind therefore costs the entire Tailscale
SMB path** - the opposite of the intent. The change was rolled back to `bind interfaces only = no`
and the node returned to its prior state (verified: both paths reachable, six sessions intact).

This also explains a comment that was already in `smb.conf`: *"Robust: listen on all available
interfaces (avoid bind failures)"*, above a commented-out `interfaces` line. A previous attempt hit
the same wall; the reason was simply never recorded.

## Decision

Three steps, in order of increasing risk. Step 1a is done; 1b replaces the rejected bind.

### Step 1a - drop the dead LAN entry (done 2026-07-14)

`<lan-ip-device3>` removed from `hosts allow`. It carried no session and its client log had been
empty since 2026-06-17. The desktop behind it holds `tag:admin`, which ACL Rule 1 grants full
access to `tag:storage` - so it keeps SMB access over Tailscale and loses nothing.

### Step 1b - enforce the boundary in the kernel, not in Samba (done 2026-07-14)

Since Samba cannot be made to bind correctly, the boundary moves one layer down, to an nftables
rule on VM102. This is strictly better than the `interfaces` approach it replaces: it is a kernel
packet filter evaluated before Samba sees the connection, whereas `hosts allow` runs *after* the
TCP accept, inside the application.

Scope, on the LAN interface `ens18` only:

- **Drop all inbound TCP/445 over IPv6.** This closes the world-routable socket - the one exposure
  that today depends on a consumer router's default setting. No consumer is affected: every SMB
  session on this node is IPv4 (`smbstatus`).
- **Allow inbound TCP/445 over IPv4 only from `<lan-ip-vm100>` and `<lan-ip-proxmox>`; drop the
  rest.** These are the only two LAN clients that hold sessions. Tailscale traffic is unaffected -
  it arrives on `tailscale0`, not `ens18`.

The admin workstation is not affected either: it sits on the LAN but mounts over the Tailscale IP,
so its packets arrive on `tailscale0`.

**The trap to avoid:** Debian's stock `/etc/nftables.conf` begins with `flush ruleset`. Enabling
`nftables.service` with that file would wipe Tailscale's own chains at every boot (`ts-input`,
`ts-forward`, the `ip nat` masquerade chain), which is a far worse failure than the open port it
fixes. The rule therefore lives in its own table (`table inet smb_guard`) loaded by its **own
unit**, never through `nftables.service`, and the file contains no `flush ruleset`. Tables in
nftables are independent: a `drop` in any table drops the packet, so no coordination with
Tailscale's rules is needed.

Rollback is `nft delete table inet smb_guard` - one command, effective immediately.

Planned ruleset (`/etc/nftables.d/smb-guard.nft`). The `table`/`delete table` prelude makes the
file re-appliable: `nft -f` on an already-loaded table would otherwise fail, and declaring an
empty table before deleting it makes the delete succeed on a *first* run too.

```nft
table inet smb_guard
delete table inet smb_guard

table inet smb_guard {
  chain input {
    type filter hook input priority filter; policy accept;

    # LAN interface only. Tailscale traffic arrives on tailscale0 and is never seen here.
    iifname != "ens18" accept

    # The point of this table: no SMB over the globally routable IPv6 on ens18.
    meta nfproto ipv6 tcp dport 445 counter drop

    # SMB over LAN IPv4: only the two nodes that actually mount (vm100, Proxmox host).
    ip saddr { <lan-ip-vm100>, <lan-ip-proxmox> } tcp dport 445 counter accept
    tcp dport 445 counter drop
  }
}
```

The counters matter: after a week, `nft list table inet smb_guard` shows whether anything is being
dropped that should not be - the empirical check that this rule set did not break a consumer
nobody remembered.

Loaded by a dedicated unit (`smb-guard.service`, `Type=oneshot`, `RemainAfterExit=yes`,
`After=network-pre.target`, `ExecStart=/usr/sbin/nft -f /etc/nftables.d/smb-guard.nft`,
`ExecStop=/usr/sbin/nft delete table inet smb_guard`). It must not be `nftables.service`,
whose `ExecStop` flushes the whole ruleset and would take Tailscale's chains with it.

Deployed sources: [smb-guard.nft](../../snippets/storage/smb-guard.nft),
[smb-guard.service](../../snippets/systemd/smb-guard.service).

**Result (measured, 2026-07-14).** Applied, then proved across a reboot of VM102 - the only test
that distinguishes "works" from "comes back":

- Counters after load: 99 packets accepted (VM100 + Proxmox host, unaffected), 3 dropped
  (the SYN retries of a deliberate probe from the admin workstation's LAN address), 0 on the
  IPv6 rule - nothing had ever tried.
- Tailscale's `ts-input` / `ts-forward` chains intact (8 rule lines, unchanged).
- After reboot: table loaded by the unit, all six CIFS mounts on the Proxmox host and both on
  VM100 back with successful read tests, all eight SMB sessions re-established.
- From the admin workstation: Tailscale `:445` open, LAN `:445` refused - as intended, since it
  is neither VM100 nor the Proxmox host and reaches the share over `tailscale0` anyway.

`hosts allow` remains in place underneath as a second line of defence. It is now redundancy
rather than the only control.

### Step 2 - migrate the mounts (deferred, separate change)

**The Samba bind limitation does not block this.** It constrains what `smbd` can *listen* on, not
what a client can *connect to*: `smbd` listens on the wildcard address and therefore accepts
sessions arriving on `tailscale0` perfectly well. The proof has been running for weeks - the
Proxmox host's `/mnt/smb/postgres-backups` mount points at `//<tailscale-ip-vm102>/Postgres-Backups`
(changed 2026-06-12) and came straight back after this node's reboot, and the admin workstation
mounts the same way. Step 2 changes only the target address in `fstab`, nothing about binding.

Move the seven CIFS mounts (five on the Proxmox host, two on VM100) from the LAN IP to VM102's
Tailscale IP, one at a time, each with automount and `x-systemd.mount-timeout`, each verified
across a reboot.

**Corrected end state.** An earlier draft of this document said the LAN address would then leave
Samba's `interfaces` list. That is impossible - `interfaces` cannot be used at all on this node.
The end state is instead a tightened `smb_guard` table: once all seven mounts arrive over
Tailscale, the IPv4 exception for VM100 and the Proxmox host is deleted and the table drops
*everything* on port 445 arriving on `ens18`, v4 and v6 alike. Only `tailscale0` remains - which
is exactly what the platform binding rule intends, enforced one layer below where Samba could
deliver it.

This is deliberately not bundled into step 1. A mount that depends on Tailscale can fail at
boot before `tailscaled` has connected - the KE-9 / KE-12 fault class, and precisely the mechanism
behind KE-15, where a silently failed mount left a bind pointing at an empty directory for a
month. Moving seven mounts into that dependency without automount and timeouts in place would
invite a second KE-15. KE-15 must be repaired first.

## Consequences

- `smbd` keeps listening on `0.0.0.0:445` and `[::]:445`. That is accepted deliberately: the
  socket stays open, but after step 1b nothing can reach it over the routable IPv6, and only two
  LAN addresses can reach it over IPv4. The enforcement point moves from the application to the
  kernel; the listener itself is cosmetic. `samba.md` must say so rather than claim a bind that
  Samba cannot perform.
- Because no explicit bind is set, `smbd` startup does not depend on `tailscaled` - it listens
  on the wildcard address and picks up `tailscale0` whenever it appears. This is the one upside of
  the Samba limitation, and it is why the boot-order drop-in (`After=tailscaled.service`) written
  during the failed attempt was removed again: with a wildcard bind it delays startup for nothing.
  The coupling only becomes real in step 2, on the mount side.
- Access control on the LAN path remains address-based until step 2 completes - now in the kernel
  rather than in Samba, but still an address. An IP is not an identity: it can change by DHCP and
  it can be spoofed on the LAN. This is the residual risk step 2 removes.
- Break-glass: with a Tailscale-only Samba (post step 2), a tailnet outage would also cut data
  access. The answer is not a permanently open LAN rule but the Proxmox console, which reaches
  VM102 independently of Tailscale and can re-add access when genuinely needed.

## Verification

Step 1a (done). On VM102:

```bash
testparm -s | grep 'hosts allow'   # <lan-ip-device3> gone
smbstatus -b                       # sessions from vm100 and the Proxmox host intact
```

Step 1b, on VM102 after loading the table:

```bash
nft list table inet smb_guard      # rules present, counters visible
ss -tlnp | grep 445                # unchanged: wildcard listeners, by design
smbstatus -b                       # existing sessions unaffected
```

From the admin workstation - the Tailscale path must still answer, the LAN path must now be
refused (the workstation is neither vm100 nor the Proxmox host):

```bash
ncat -z -w3 <tailscale-ip-vm102> 445   # expect: open
ncat -z -w3 <lan-ip-vm102> 445         # expect: refused/timeout after step 1b
```

On the Proxmox host and VM100, the mounts must survive - and must still be there after a **reboot
of VM102**, which is the only test that proves the unit loads the table at boot:

```bash
findmnt -t cifs -o TARGET,SOURCE
```

## References

- [Samba architecture](../platform/samba.md)
- [Tailscale ACL model](../platform/tailscale-acl.md)
- [Known errors: KE-15 (mount fault class)](../platform/known-errors.md#ke-15)
- [PostgreSQL Tailscale boot ordering](postgresql-tailscale-boot-ordering.md) - same coupling,
  solved once already
- Reference config: [smb.conf.storage-vm102.sanitized.conf](../../snippets/storage/smb.conf.storage-vm102.sanitized.conf)
