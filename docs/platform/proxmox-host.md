# Proxmox Host

This document describes the Proxmox VE hypervisor — the bare-metal layer that runs all VMs and LXCs.

Unlike the node docs in `docs/nodes/`, this covers host-level configuration that lives outside any container: cron jobs, deployed scripts, disk passthrough, and boot ordering.

## Runtime Characteristics

- OS: Proxmox VE (Debian-based)
- Tailscale hostname: server
- Tailscale variable: `proxmox_host_tailscale_ip` (see `ansible/inventory/hosts.yml.example`)
- Managed nodes: VM100, VM102, LXC200–LXC260

## Boot Ordering

VMs and LXCs start in dependency order after the hypervisor is up:

| Layer | Node | Startup order | Delay |
|---|---|---|---|
| 1 — Storage | VM102 | 1 | 30s |
| 2 — Compute | VM100 | 2 | 20s |
| 3 — Services | LXC200–LXC260 | 3 | 20s |

Startup order and delays are configured per VM/LXC in the Proxmox guest config. VM102 must be fully up (SMB reachable) before service LXCs start to avoid mount failures.

## pveproxy Tailscale-IP Boot Ordering

`pveproxy` (the web UI / API proxy on `:8006`) binds only the host Tailscale IP
(`/etc/default/pveproxy` → `LISTEN_IP=<tailscale-ip-proxmox-host>`) to keep the
management UI on the tailnet, off the LAN. Because that IP only exists after
`tailscaled` starts, pveproxy lost a boot race and failed to bind with `Cannot
assign requested address` until manually restarted (2026-06-25).

Gated via a systemd drop-in
`/etc/systemd/system/pveproxy.service.d/wait-tailscale.conf` (`After=`/`Wants=tailscaled.service`
+ an `ExecStartPre` poll until the Tailscale IP is on `tailscale0`). Same fault
class and pattern as the PostgreSQL Tailscale-IP boot race on LXC260.

See: [KE-12](./known-errors.md#ke-12-pveproxy-fails-to-start-after-boot-tailscale-ip-bind-race),
[ADR pveproxy-tailscale-boot-ordering](../decisions/pveproxy-tailscale-boot-ordering.md),
[runbook](../../runbooks/platform/pveproxy-tailscale-boot-race.md).

## Disk Passthrough (VM102)

Data and parity disks for VM102 are passed through by ID from the host:

```
/dev/disk/by-id/<disk-id>
```

Exact disk models and IDs are documented offline. See [VM102 node doc](../nodes/vm102.md) for the logical topology.

## Aux1TB Auxiliary Disk (Failed 2026-06-25)

Aux1TB is a host auxiliary disk mounted at `/mnt/aux1TB` (fstab entry with
`nofail`). It backs the Docker data-root of the Docker-in-LXC services (per the
"Adding a New Service" checklist) and stores VM100's `jellyfin-data` `.raw` image.

On 2026-06-25 it failed with unrecoverable medium errors and would not mount — the
original cause of the emergency-mode lockout and of LXC200/211/220/230/260 failing
to start. All live data was rescued read-only before any repair attempt; the disk
is pending decommission. The `nofail` entry keeps the boot out of emergency mode in
the meantime.

See: [KE-13](./known-errors.md#ke-13-aux1tb-physical-disk-failure-medium-errors),
[incident write-up](./incidents/2026-06-25-aux1tb-failure-and-recovery.md),
[Aux1TB rescue runbook](../../runbooks/storage/aux1tb-failure-rescue.md).

## Host Cron Jobs

Managed via `/etc/cron.d/homelab-schedule`. Managed by the `homelab-schedule` Ansible role (see [Ansible platform](./ansible.md)).

| Schedule | User | Script | Purpose |
|---|---|---|---|
| `45 0 * * *` | root | `/usr/local/sbin/homelab-setwake.sh` | Program RTC wakeup alarm for tomorrow before shutdown |
| `0 1 * * *` | root | `/usr/local/sbin/homelab-shutdown.sh` | Scheduled nightly shutdown (2h buffer after SnapRAID sync at 23:00 on VM102) |

### Wake Times (homelab-setwake.sh)

The script programs the RTC alarm via `rtcwake -m no -t <unix-timestamp>` based on the next day:

- **Tuesday, Wednesday** (day 2 or 3): wake at **16:00**
- **All other days**: wake at **07:30**

Source: `scripts/homelab-setwake.sh` — deployed to `/usr/local/sbin/homelab-setwake.sh`.

### Shutdown (homelab-shutdown.sh)

Runs `shutdown -h now`. The 01:00 schedule gives a 2-hour buffer after the SnapRAID sync on VM102 (23:00 daily) — the order is: sync completes → host shuts down → RTC wakes host at configured time.

Source: `scripts/homelab-shutdown.sh` — deployed to `/usr/local/sbin/homelab-shutdown.sh`.

Source: `scripts/homelab-shutdown.sh` — deployed to `/usr/local/sbin/homelab-shutdown.sh`.

## Ansible Management

The Proxmox host is **not yet a fully managed Ansible node**. The `homelab-schedule` role manages the power-schedule scripts and cron file. Full host management (package updates, SSH hardening) is not implemented.

To run the schedule role against the host:

```bash
ansible-playbook playbooks/homelab-schedule.yml
```

Requires: the `proxmox` group in `hosts.yml` to be populated with the host's Tailscale IP.

See: [Ansible platform](./ansible.md)

## Related Documents

- [Operations](./operations.md) — boot ordering and maintenance routines
- [VM102 — Storage](../nodes/vm102.md) — SnapRAID cron schedule on VM102
- [ansible/roles/homelab-schedule/](../../ansible/roles/homelab-schedule/) — role that deploys scripts + cron file
