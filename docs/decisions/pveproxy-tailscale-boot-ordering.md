# pveproxy Boot Ordering: Gate Startup on the Tailscale IP

## Context

The Proxmox web UI / API proxy (`pveproxy`) is configured to bind **only the host
Tailscale IP** via `/etc/default/pveproxy`:

```
LISTEN_IP=<tailscale-ip-proxmox-host>
```

This is intentional: it keeps the management UI on the tailnet, off the LAN. It
also means pveproxy can only start if that IP already exists on an interface.

On boot, `pveproxy.service` starts before `tailscaled` has assigned the Tailscale
IP. pveproxy can only bind an address that exists at startup, so it fails:

```
start failed - unable to create socket - Cannot assign requested address
```

(kernel `EADDRNOTAVAIL`). The default unit retries quickly and systemd gives up
after five attempts:

```
pveproxy.service: Start request repeated too quickly.
pveproxy.service: Failed with result 'exit-code'.
```

Unlike PostgreSQL (KE-9), pveproxy does **not** fall back to a partial bind — it
exits non-zero and stays dead until a manual `systemctl restart pveproxy`. The web
UI is then unreachable after every boot until someone intervenes (and they can
only intervene over SSH, which is the failure this hardening was meant to avoid).
Full incident:
[KE-12](../platform/known-errors.md#ke-12-pveproxy-fails-to-start-after-boot-tailscale-ip-bind-race).

Verified root cause (not inferred): the journal shows five `Cannot assign
requested address` failures within ~4 s of boot, and a clean bind to
`<tailscale-ip-proxmox-host>:8006` only after a manual restart once the IP was
present.

This is the same fault class as the PostgreSQL boot race; see
[PostgreSQL Boot Ordering ADR](./postgresql-tailscale-boot-ordering.md).

## Decision

Gate pveproxy startup on the Tailscale IP actually being present, via a systemd
drop-in at `/etc/systemd/system/pveproxy.service.d/wait-tailscale.conf`:

```ini
[Unit]
After=tailscaled.service
Wants=tailscaled.service

[Service]
ExecStartPre=/bin/bash -c 'for i in $(seq 1 30); do ip -4 addr show tailscale0 2>/dev/null | grep -q <tailscale-ip-proxmox-host> && exit 0; sleep 1; done; exit 1'
```

Two parts, both required (identical reasoning to the PostgreSQL ADR):

1. **Ordering** (`After=`/`Wants=tailscaled.service`) — start after the tailscaled
   *daemon*. Necessary but not sufficient: the daemon being up does not mean the IP
   is assigned yet (assignment is asynchronous).
2. **Wait-for-IP gate** (`ExecStartPre`) — poll until the Tailscale IP is present
   on `tailscale0`, up to 30 s, then let pveproxy start. This closes the race the
   ordering alone leaves open.

The gate runs as an additional `ExecStartPre`, after the existing
`pvecm updatecerts` step. Validated by a controlled restart with the drop-in
active: the wait returned immediately (IP already present) and pveproxy bound
`<tailscale-ip-proxmox-host>:8006` (HTTP 200).

## Alternatives Considered

### Remove `LISTEN_IP` / bind all interfaces (rejected)

Letting pveproxy bind `0.0.0.0` sidesteps the race. Rejected for the same reason as
`listen_addresses = '*'` in the PostgreSQL ADR: it re-exposes the management UI on
the **LAN**, violating the platform binding rule (bind to Tailscale, never LAN).
The whole point of `LISTEN_IP` here is to keep `:8006` off the LAN.

### `net.ipv4.ip_nonlocal_bind=1` (rejected)

A sysctl that lets any process bind an address that does not yet exist would let
pveproxy bind the Tailscale IP before `tailscaled` assigns it. Rejected: it is a
**system-wide** change to bind semantics for every process on the host, to fix one
service's ordering — too broad a blast radius for a targeted boot race.

### `After=tailscaled.service` alone (insufficient)

Ordering after the daemon does not guarantee the IP is assigned (asynchronous).
Same conclusion as the PostgreSQL ADR — the explicit poll is what closes the race.

## Consequences

### Accepted

- pveproxy startup is delayed until the Tailscale IP appears (observed
  immediately when the IP is already up after a warm restart; the cold-boot delay
  is bounded by the 30 s poll).
- One more `ExecStartPre` step on a host-level service.
- The gate **fails closed** on timeout (`exit 1` after 30 s) — if the Tailscale IP
  never appears, pveproxy does not start. This differs from the PostgreSQL gate
  (fail-open). It is acceptable here because pveproxy is a management plane, not a
  data service: a hard fail is visible and recoverable over SSH, and there is no
  "loopback-only degraded mode" worth preserving for a UI bound to one IP.

### Verification

Reboot the host and confirm pveproxy bound on a *fresh* boot (the only test that
exercises the race):

```bash
systemctl is-active pveproxy
ss -ltnp | grep 8006        # bound on <tailscale-ip-proxmox-host>:8006 ?
```

Cold-boot verification is still **pending** — the fix was validated only by a warm
restart so far; the next reboot (e.g. during the planned GPU swap) is the real test.

## Follow-up: align with the canonical pattern

The repo already solves this exact class for PostgreSQL with a reusable
`wait-for-tailscale-ip.sh` (`snippets/scripts/`) deployed by the
`postgresql-boot-order` Ansible role. The pveproxy fix is currently an inline poll
loop. The durable form is to reuse the shared script and manage the drop-in via
Ansible, so both services share one source of truth for "wait for the Tailscale
IP". Deferred to a host-Ansible-management work item.

## Related Documents

- [KE-12 — pveproxy Tailscale-IP bind race](../platform/known-errors.md#ke-12-pveproxy-fails-to-start-after-boot-tailscale-ip-bind-race)
- [PostgreSQL Boot Ordering ADR](./postgresql-tailscale-boot-ordering.md) — same fault class, fail-open variant
- [Runbook — pveproxy boot-race recovery](../../runbooks/platform/pveproxy-tailscale-boot-race.md)
- [Proxmox Host](../platform/proxmox-host.md)
