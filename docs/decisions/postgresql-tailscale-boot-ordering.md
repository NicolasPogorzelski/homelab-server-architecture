# PostgreSQL Starts Only After the Tailscale Address Exists

## Status
Implemented 2026-06-09 (`postgresql_boot_order` role). Supersedes / superseded by: -.

## Context
lxc260 runs the platform PostgreSQL. It listens on loopback and its Tailscale address only
(`listen_addresses = '127.0.0.1, <tailscale-ip-lxc260>'`), never on the LAN. Consumers such as
OpenWebUI and Paperless-ngx reach it over Tailscale on 5432.

`postgresql@15-main.service` was ordered only `After=network.target`, which is reached before
`tailscaled` assigns the node's address. PostgreSQL bound loopback, logged

```
could not bind IPv4 address "<tailscale-ip-lxc260>": Cannot assign requested address
```

and continued with loopback only; the Tailscale bind was never retried, so every remote consumer
failed until a manual restart. The PostgreSQL log shows the failure on the 2026-06-07 and 2026-06-08
boots and a clean bind after the restart ([KE-9](../platform/known-errors.md#ke-9)).

## Options
- **`listen_addresses = '*'`.** Also binds the LAN interface. `pg_hba.conf` would still gate
  authentication, but a listener on an untrusted network is an exposure regression.
- **`After=network-online.target`.** `tailscaled` does not register with the wait-online
  services, so the target can be reached before the Tailscale address exists.
- **A fail-closed gate.** A slow `tailscaled` would take the whole database offline, loopback
  included - worse than the original bug for a central database.
- **Order after `tailscaled` and gate fail-open on the address being present.** Chosen.

## Decision
A drop-in on `postgresql@15-main.service`:

```ini
[Unit]
Wants=tailscaled.service
After=tailscaled.service

[Service]
ExecStartPre=/usr/local/bin/wait-for-tailscale-ip.sh 90
```

Ordering after the daemon is necessary but not sufficient; the script polls until the node's
`tailscale ip -4` address appears in `ip -4 addr show`. On timeout it logs a warning and exits 0,
so PostgreSQL still starts on loopback.

The `postgresql_boot_order` role deploys the drop-in and the script; the script's single source is
`snippets/scripts/wait-for-tailscale-ip.sh`, also used by `tailscale_boot_gate` on other nodes.
Migrating lxc260 onto `tailscale_boot_gate` is deferred: the current role works and is cold-boot
verified.

## Consequences
- Startup waits for the address; observed about 2 s after boot. `TimeoutStartSec=0` on the unit
  keeps the wait from tripping a start timeout.
- A `tailscaled` timeout reproduces the old loopback-only state instead of failing hard. That is
  visible through the blackbox probes and `ServiceDown`, and keeps the database locally usable.
- One more `ExecStartPre` on the database node.

## Verification
After a fresh boot of lxc260 (the only test that exercises the race):

```bash
ss -ltnp | grep 5432                       # 127.0.0.1 and the Tailscale address
journalctl -u postgresql@15-main.service -b 0 | grep wait-for-tailscale-ip
```

First post-fix boot: the gate reported `tailscale IP present after 2s`, and the log showed
`listening on IPv4 address "<tailscale-ip-lxc260>"` with no bind error. The host boots cold every
morning, so the path is exercised daily.

## Related Documents
- [KE-9 - PostgreSQL loopback-only after boot](../platform/known-errors.md#ke-9)
- [pveproxy boot ordering](pveproxy-tailscale-boot-ordering.md) - same class
- [LXC260 PostgreSQL node](../nodes/lxc260.md)
- [Ansible Platform](../platform/ansible.md)
