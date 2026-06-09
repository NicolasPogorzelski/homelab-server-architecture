# PostgreSQL Boot Ordering: Gate Startup on the Tailscale IP

## Context

LXC260 runs the central PostgreSQL. Per the platform binding rule it listens on
loopback **and its Tailscale IP only** (`listen_addresses = '127.0.0.1,
<tailscale-ip-lxc260>'`), never on `0.0.0.0`/LAN. Remote consumers
(OpenWebUI, Paperless, …) reach it over Tailscale on `:5432`.

On boot, `postgresql@15-main.service` ordered only `After=network.target`. That
target is reached very early — **before** `tailscaled` has assigned the node's
Tailscale IP to an interface. PostgreSQL can only bind addresses that exist at
startup, so it bound loopback, logged

```
could not bind IPv4 address "100.x.y.z": Cannot assign requested address
```

(kernel `EADDRNOTAVAIL`), and continued with loopback only (the unit's
`ExecStart=-…` ignores startup failures). The Tailscale bind was never retried →
all remote DB consumers failed until a manual `systemctl restart postgresql`.
Full incident: [KE-9](../platform/known-errors.md#ke-9-postgresql-binds-only-loopback-after-boot-tailscale-ip-startup-race).

Verified root cause (not inferred): the postgres log shows the bind failure on
the 2026-06-07 and 2026-06-08 boots, and a clean bind only after the manual
restart once the IP was present.

## Decision

Gate PostgreSQL startup on the Tailscale IP actually being present, via a systemd
drop-in on `postgresql@15-main.service`:

```ini
[Unit]
Wants=tailscaled.service
After=tailscaled.service

[Service]
ExecStartPre=/usr/local/bin/wait-for-tailscale-ip.sh 90
```

Two parts, both required:

1. **Ordering** (`After=`/`Wants=tailscaled.service`) — start PostgreSQL after
   the tailscaled *daemon*. Necessary but **not sufficient**: tailscaled being up
   does not mean the IP is assigned yet (it happens asynchronously after the
   daemon starts).
2. **Wait-for-IP gate** (`ExecStartPre`) — `wait-for-tailscale-ip.sh` polls until
   this node's `tailscale ip -4` is actually present in `ip -4 addr show`, then
   lets PostgreSQL start. This closes the race the ordering alone leaves open.

Codified as the Ansible role `postgresql-boot-order` (deploys the script +
drop-in); the script's single source of truth is
`snippets/scripts/wait-for-tailscale-ip.sh`.

## Alternatives Considered

### `listen_addresses = '*'` (rejected)

Binding all interfaces sidesteps the race — PostgreSQL would bind `0.0.0.0` and
pick up the Tailscale IP whenever it appears. Rejected: it also binds the **LAN
interface**, violating the platform binding rule (bind to Tailscale, never LAN).
`pg_hba.conf` would still gate authentication, but defence-in-depth means not
opening a listener on an untrusted network in the first place. "Fix the bind race
by listening everywhere" trades a correctness bug for an exposure regression.

### `After=network-online.target` (insufficient)

`network-online.target` is the right idea (it means "network is configured", not
just the early `network.target`), but it is only as good as the network manager
backing it. tailscaled does not register its interface with
`systemd-networkd-wait-online`/`NetworkManager-wait-online`, so the target can be
reached before the Tailscale IP exists. It would not reliably gate on the one
address we care about. The explicit poll does.

### Fail-closed wait (rejected in favour of fail-open)

The gate script could exit non-zero on timeout, failing the unit so PostgreSQL
does not start without its Tailscale IP. Rejected: a slow/broken tailscaled would
then take the **entire** database offline, including loopback — worse than the
original bug for a central platform DB. The script is **fail-open**: on timeout
(default 90s) it logs a warning and exits 0, so PostgreSQL still starts (loopback
at minimum). A timeout is an exceptional condition the existing `blackbox` /
`ServiceDown` monitoring already surfaces.

## Consequences

### Accepted

- PostgreSQL startup is delayed by the time it takes the Tailscale IP to appear
  (observed ~2s after this node's boot). `TimeoutStartSec=0` on the unit means
  the wait does not trip a start timeout.
- One more moving part (a poll script as `ExecStartPre`) on the DB node.
- Fail-open means a (rare) tailscaled timeout reproduces the old loopback-only
  state rather than failing hard — accepted, because it is detectable and keeps
  the DB locally usable.

### Verification

Reboot LXC260 and confirm PostgreSQL bound the Tailscale IP on a *fresh* boot
(the only test that actually exercises the race):

```bash
ss -ltnp | grep 5432                                   # both 127.0.0.1 and the Tailscale IP?
journalctl -u postgresql@15-main.service -b 0 | grep wait-for-tailscale-ip
```

First post-fix boot: gate reported `tailscale IP present after 2s`, log showed
`listening on IPv4 address "<tailscale-ip>"` with no bind error.

## Related Documents

- [KE-9 — PostgreSQL loopback-only after boot](../platform/known-errors.md#ke-9-postgresql-binds-only-loopback-after-boot-tailscale-ip-startup-race)
- [LXC260 PostgreSQL node](../nodes/lxc260.md)
- [Ansible Platform](../platform/ansible.md)
- devops-til: `systemd/service-ordering-and-runtime-gates.md` (the transferable concept)
