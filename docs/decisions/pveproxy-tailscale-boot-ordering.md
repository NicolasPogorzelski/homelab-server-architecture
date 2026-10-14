# pveproxy Starts Only After the Tailscale Address Exists

## Status
Implemented 2026-06-25; managed by the `tailscale_boot_gate` role since 2026-09-11. Supersedes /
superseded by: -.

Cold boot verified 2026-08-13, and exercised every day since: the host powers down nightly and
boots cold each morning ([KE-12](../platform/known-errors.md#ke-12)).

## Context
`pveproxy`, the Proxmox web UI and API proxy, binds only the host's Tailscale address through
`/etc/default/pveproxy`:

```
LISTEN_IP=<tailscale-ip-proxmox-host>
```

This keeps port 8006 off the LAN, and means pveproxy can start only once that address exists. At
boot `pveproxy.service` started before `tailscaled` had assigned it:

```
start failed - unable to create socket - Cannot assign requested address
pveproxy.service: Start request repeated too quickly.
pveproxy.service: Failed with result 'exit-code'.
```

Five `EADDRNOTAVAIL` failures within about 4 s of boot, then systemd gave up. Unlike PostgreSQL
([KE-9](../platform/known-errors.md#ke-9)), pveproxy has no partial bind: the web UI stayed down
until a manual `systemctl restart pveproxy`, after which it bound `<tailscale-ip-proxmox-host>:8006`.
Same fault class as the [PostgreSQL boot race](postgresql-tailscale-boot-ordering.md) and
[KE-18](../platform/known-errors.md#ke-18).

## Options
- **Remove `LISTEN_IP` and bind all interfaces.** Lost: puts the management UI back on the LAN.
- **`net.ipv4.ip_nonlocal_bind=1`.** Lost: changes bind semantics for every process on the host to
  fix one unit's ordering.
- **`After=tailscaled.service` alone.** Lost: the daemon being up does not mean the address is
  assigned; assignment is asynchronous.
- **Order after `tailscaled` and gate on the address being present.** Chosen.

## Decision
A drop-in on `pveproxy.service` orders it after `tailscaled.service` (`After=` and `Wants=`) and
runs `wait-for-tailscale-ip.sh` as an additional `ExecStartPre`, after the packaged
`pvecm updatecerts` step. The script polls until the node's `tailscale ip -4` address is present.

The drop-in is rendered by `tailscale_boot_gate` from `ansible/inventory/group_vars/proxmox.yml`
(`tailscale_boot_gate_units: [pveproxy.service]`). The script has one source,
`snippets/scripts/wait-for-tailscale-ip.sh`, shared with `postgresql_boot_order` on lxc260. The role
removes the hand-written `wait-tailscale.conf` from June, which hardcoded the address and would
otherwise override the role's file on filename order.

## Consequences
- pveproxy starts as soon as the address appears; the wait is bounded by the role's timeout
  (`tailscale_boot_gate` defaults).
- The shared script is fail-open: on timeout it logs a warning and exits 0, and pveproxy then fails
  its bind as before. The original inline gate failed closed; with no loopback mode to preserve, the
  visible outcome is the same - a dead web UI recoverable over SSH or by the runbook below.
- One more `ExecStartPre` on a host-level service.

## Verification
After a boot (only a fresh boot exercises the race):

```bash
systemctl is-active pveproxy
ss -ltnp | grep 8006        # bound on <tailscale-ip-proxmox-host>:8006
journalctl -u pveproxy -b 0 | grep -i "wait-for-tailscale-ip\|Cannot assign"
```

## Related Documents
- [KE-12 - pveproxy Tailscale-IP bind race](../platform/known-errors.md#ke-12)
- [PostgreSQL boot ordering](postgresql-tailscale-boot-ordering.md) - same class, a service with a
  loopback fallback
- [Runbook - pveproxy boot-race recovery](../../runbooks/platform/pveproxy-tailscale-boot-race.md)
- [Proxmox Host](../platform/proxmox-host.md)
