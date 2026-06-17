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

## Disk Passthrough (VM102)

Data and parity disks for VM102 are passed through by ID from the host:

```
/dev/disk/by-id/<disk-id>
```

Exact disk models and IDs are documented offline. See [VM102 node doc](../nodes/vm102.md) for the logical topology.

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
