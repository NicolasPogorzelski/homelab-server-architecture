# Runbook: Hard Shutdown Recovery (Proxmox)

## Problem

The Proxmox host was shut down uncleanly — power loss, forced power-off, or hardware
watchdog. After reboot, one or more LXC containers fail to start automatically. SSH to
managed nodes may be temporarily unavailable.

Observed failure modes:

- **LXC260 (postgres):** pre-start hook exits with code 19 (`ENODEV`) — the SMB bind
  mount at `/mnt/smb/postgres-backups` is not ready when Proxmox tries to start the container
- **LXC250 (devops):** SSH unreachable for ~30–60 s after boot — sshd binds only to the
  Tailscale IP; it is unreachable until Tailscale connects

## Preconditions

- Proxmox host has finished booting (power LED stable, network link up)
- Access via one of the methods in the table below

---

## Access Hierarchy

Use the first available method:

| Priority | Method | Address | Available when |
|---|---|---|---|
| 1 | Proxmox WebUI (Tailscale) | `https://<tailscale-ip-proxmox-host>:8006` | Tailscale on host is connected |
| 2 | Proxmox WebUI (LAN) | `https://<proxmox-lan-ip>:8006` | On same LAN as server |
| 3 | SSH to Proxmox host (LAN) | `ssh root@<proxmox-lan-ip>` | LAN reachable, sshd up |
| 4 | LXC console | WebUI → container → Console tab | Proxmox WebUI accessible |

**Finding `<proxmox-lan-ip>`:** Open the Fritz!Box at `http://<router-lan-ip>` →
Heimnetz → Netzwerk. The host appears as `server` or `pve`. Alternatively:
`arp -n` from any device on the same LAN.

---

## Diagnosis

**List container states** (on Proxmox host via SSH or WebUI shell):

```bash
pct list
```

Stopped containers show `stopped` in the Status column.

**Check why a container failed to start:**

```bash
journalctl -u pve-container@<ctid>.service --no-pager -n 30
```

Common exit codes:

| Code | Meaning | Context |
|---|---|---|
| 19 (`ENODEV`) | Bind-mount path not found | Storage not ready; LXC260 mp1 |
| 1 | Generic failure | Check full journal for details |

---

## Recovery

### Step 1 — Verify storage mounts are ready

LXC260 depends on `mp1`: `/mnt/smb/postgres-backups` bound from VM102/storage.
Start LXC260 only after confirming the path exists on the Proxmox host:

```bash
ls /mnt/smb/postgres-backups
```

If the path is missing or empty, VM102/storage is still booting. Wait 30–60 s and retry.

### Step 2 — Start stopped containers

Start in dependency order — storage-dependent containers last:

```bash
pct start 200   # monitoring
pct start 210   # nextcloud
pct start 211   # paperless
pct start 220   # calibreweb
pct start 230   # openwebui
pct start 240   # vaultwarden
pct start 250   # devops
pct start 260   # postgres — start last, depends on SMB from VM102
```

Skip containers that are already running (`pct start` on a running container returns an error
but causes no harm).

### Step 3 — Restore SSH access to LXC250

LXC250's sshd is configured with `ListenAddress <tailscale-ip-devops>`. After boot,
SSH is unreachable until Tailscale connects. Check Tailscale status inside the container:

```bash
pct exec 250 -- tailscale status
```

Expected: a line showing `devops` with a `100.x.x.x` address. If Tailscale is still
connecting, wait and retry. If it is stuck:

```bash
pct exec 250 -- systemctl restart tailscaled
```

Once Tailscale is connected, SSH via the Tailscale IP works normally.

---

## Verification

```bash
# All containers in running state
pct list

# All Ansible-managed nodes reachable via Tailscale
cd ~/git/homelab-server-architecture/ansible
ansible all -m ping

# PostgreSQL accepting connections
pct exec 260 -- systemctl status postgresql --no-pager
```

---

## Failure Modes

| Symptom | Likely Cause | Action |
|---|---|---|
| `pct start 260` fails, exit 19 | SMB mount not ready (VM102 still booting) | Wait, then `ls /mnt/smb/postgres-backups`; retry `pct start 260` |
| SSH to LXC250 — connection refused immediately | sshd bound to Tailscale IP, Tailscale not yet up | Wait 60 s; check `pct exec 250 -- tailscale status`; restart tailscaled if stuck |
| Container starts but services in failed state | Systemd units left in failed state after unclean shutdown | `pct exec <ctid> -- systemctl --failed`; restart affected units |
| Proxmox WebUI unreachable via Tailscale | Tailscale on Proxmox host not connected | Use LAN IP for WebUI; `ssh root@<proxmox-lan-ip>` → `systemctl restart tailscaled` |
| Container filesystem errors on boot | fsck required after unclean unmount | Container will auto-fsck; check `journalctl -u pve-container@<ctid>` for outcome; manual `fsck` rarely needed |
| `ansible all -m ping` shows some UNREACHABLE | Tailscale on affected node not yet connected | Wait 30–60 s; retry ping; or check `pct exec <ctid> -- tailscale status` |

---

## Prevention

- **Always use a controlled shutdown:** Proxmox WebUI → node → Reboot, or `shutdown -r now`
  via SSH. Forced power-off should only be used if the host is completely unresponsive.
- **If the host becomes unresponsive during high I/O:** Open Proxmox WebUI first (Tailscale).
  The WebUI remains accessible even when SSH is saturated. Use WebUI → node → Shell to
  investigate before resorting to a hard shutdown.
- **LXC260 startup delay:** Currently `order=2, up=20s`. If SMB mount failures recur after
  clean reboots, increase the `up` delay in the LXC config via Proxmox WebUI → LXC260 →
  Options → Start/Shutdown Order.

---

## Notes

- LXC250 `ListenAddress` is intentional hardening (SSH binds to Tailscale only, no LAN
  exposure). The ~60 s post-boot window where SSH is unreachable is a known tradeoff.
  See: [Known Technical Debt](../../CLAUDE.md#known-technical-debt--gotchas)
- LXC260 `mp1` (`/mnt/smb/postgres-backups`) is populated by VM102/storage. Hard shutdowns
  can break this boot dependency. See: [Known Technical Debt](../../CLAUDE.md#known-technical-debt--gotchas)
- See also: [LVM Thin Pool Full](./lvm-thin-pool-full.md) — if the high I/O was caused by
  pool overflow (check `lvs -o lv_name,data_percent` on the Proxmox host)
