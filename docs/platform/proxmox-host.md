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

| Startup order | Node(s) | Delay | Role |
|---|---|---|---|
| 1 | VM102 | 30s | Storage (SMB must be reachable before dependents) |
| 2 | LXC200, LXC260 | 20s | Monitoring, PostgreSQL platform |
| 3 | LXC210, LXC211 | 20s | Nextcloud, Paperless |
| 4 | LXC240 | 20s | Vaultwarden |
| 5 | LXC220, LXC230 | 20s | Calibre-Web, OpenWebUI |
| 6 | VM100 | 40s | Compute / GPU media |

Startup order and delays are configured per VM/LXC in the Proxmox guest config (`startup: order=N,up=M`). VM102 must be fully up (SMB reachable) before storage-dependent nodes start, to avoid mount failures. VM100 (compute/GPU) starts last — its media services depend on VM102 storage but nothing depends on VM100 at boot.

## Disk Passthrough (VM102)

Data and parity disks for VM102 are passed through by ID from the host:

```
/dev/disk/by-id/<disk-id>
```

Exact disk models and IDs are documented offline. See [VM102 node doc](../nodes/vm102.md) for the logical topology.

## Host Cron Jobs

Deployed as `/etc/cron.d/homelab-schedule`, currently **managed manually** (deployed 2026-05-23). A `homelab-schedule` Ansible role exists to codify these scripts + cron file but has **not yet been applied** to the live host (see [Ansible platform](./ansible.md)).

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

## Ansible Management

The Proxmox host is **not yet a fully managed Ansible node**. A `homelab-schedule` role exists to manage the power-schedule scripts and cron file, but it has not yet been applied — those are currently deployed manually. Full host management (package updates, SSH hardening) is not implemented.

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
