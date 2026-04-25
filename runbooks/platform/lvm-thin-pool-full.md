# Runbook: LVM thin-pool full (Proxmox)

## Problem

The `local-lvm` thin-pool on the Proxmox host reaches 100% utilization. QEMU VMs enter
`io-error` state and suspend. LXC containers continue running but all writes fail silently —
including apt downloads, which results in corrupt package archives and binary corruption
if an upgrade was in progress at the moment of overflow.

## Preconditions

- SSH or console access to the Proxmox host
- All affected VMs/LXCs are identified (`qm status <id>`, `pct status <id>`)

---

## Diagnosis

**Check pool utilization:**

```bash
lvs -o lv_name,lv_size,data_percent
```

If `data` shows `100.00`, the pool is full.

**Check for VMs in io-error state:**

```bash
qm status <vmid>
```

Expected output when frozen: `status: io-error`

**Check LXC disk space (may appear fine despite pool overflow):**

```bash
ansible lxcs -m command -a "df -h /"
```

Note: `df` inside a container reports virtual disk usage, not thin-pool utilization.
A container can show free space while the underlying pool is full.

**Check for corrupt packages on a node:**

```bash
# Inside LXC via pct exec, or inside VM via SSH
dpkg --audit
apt-get check
```

**Check for corrupt binaries:**

```bash
file /usr/sbin/tailscaled   # should be ELF, not "data"
file /bin/bash              # should be ELF, not "data"
```

---

## Recovery

### Step 1 — Free space in the pool

**On all reachable LXCs:**

```bash
ansible lxcs -m command -a "apt-get clean"
```

**fstrim via nsenter from Proxmox host** (fstrim is blocked inside LXCs):

```bash
for ctid in 200 210 211 220 230 240 260; do
  PID=$(lxc-info -n "$ctid" 2>/dev/null | awk '/^PID:/{print $2}')
  [ -z "$PID" ] && echo "lxc${ctid}: not running, skipping" && continue
  echo "lxc${ctid} (PID ${PID})..."
  nsenter -t "$PID" --mount -- fstrim -v /
done
```

**fstrim on VMs** (run from inside each VM via SSH, requires sudo):

```bash
ssh gpu@<tailscale-ip-gpu-vm> 'sudo fstrim -v /'
ssh storage@<tailscale-ip-storage> 'sudo fstrim -v /'
```

**Verify pool freed:**

```bash
lvs -o lv_name,data_percent | grep data
```

Aim for at least 15% free before proceeding.

### Step 2 — Resume frozen VMs

```bash
qm resume <vmid>
qm status <vmid>   # should return: status: running
```

### Step 3 — Repair corrupt dpkg state on affected LXCs/VMs

```bash
# Check for pending triggers / interrupted installs
pct exec <ctid> -- dpkg --audit

# Configure pending packages
pct exec <ctid> -- dpkg --configure -a

# Fix broken dependencies
pct exec <ctid> -- apt --fix-broken install -y
```

### Step 4 — Reinstall corrupt binaries

If `file <binary>` returns `data` instead of `ELF 64-bit executable`:

```bash
pct exec <ctid> -- apt-get install --reinstall <package>
```

Common victims when upgrade is interrupted mid-write:
- `tailscale` (large binary, ~40 MB)
- `bash` (upgraded frequently with security patches)
- `login`, `libpam-modules` (upgraded together)

### Step 5 — Re-run the upgrade

After pool space is restored and dpkg state is clean:

```bash
ansible-playbook ansible/playbooks/apt-upgrade.yml
```

---

## Verification

```bash
# All nodes reachable
ansible all -m ping

# Pool utilization
lvs -o lv_name,data_percent | grep data

# No broken packages on any node
ansible lxcs -m command -a "dpkg --audit"
```

---

## Failure Modes

| Symptom | Likely Cause | Action |
|---|---|---|
| `qm status <id>` returns `io-error` | VM frozen due to pool overflow | Free pool space, then `qm resume <id>` |
| `No space left on device` during apt | Thin-pool full, writes failing | Run apt clean + fstrim before retrying |
| SSH connects but `echo test` returns `Exec format error` | Binary corrupted mid-write | `apt-get install --reinstall <package>` |
| `dpkg-deb: error: not a Debian format archive` | .deb downloaded partially | `apt-get clean` on the node, re-run upgrade |
| tailscaled `Needs login` after reinstall | Auth state lost during reinstall | Re-authenticate via browser login URL in `systemctl status tailscaled` |
| tailscaled `disabled` after reinstall | Unit was not enabled before | `systemctl enable tailscaled` |
| fstrim returns `Operation not permitted` inside LXC | FITRIM ioctl blocked in LXC | Run fstrim via `nsenter` from Proxmox host (see Step 1) |
| Ansible `Failed to create temporary directory` on LXC | Disk full, can't write to `~/.ansible/tmp` | Run fstrim + apt clean via `pct exec` first |

---

## Prevention

- **Periodic fstrim:** Run `snippets/scripts/lxc-fstrim.sh` after every `apt-upgrade` playbook run. A Proxmox-host cronjob is planned.
- **Serial upgrades:** `apt-upgrade.yml` uses `serial: 1` to prevent simultaneous downloads from spiking pool utilization.
- **apt clean after upgrade:** `apt-upgrade.yml` runs `apt clean` on each node after upgrading.
- **Monitor pool utilization:** Add a Prometheus alert for `local-lvm` pool above 85%.

---

## Notes

- `df -h /` inside a container reports filesystem usage, not thin-pool utilization. Always check the pool directly via `lvs` on the Proxmox host.
- `fstrim` must be run from the Proxmox host via `nsenter` for LXCs. Running it inside an LXC fails with `FITRIM ioctl failed: Operation not permitted`.
- For VMs, `fstrim` runs normally via SSH since they have full kernel access.
- See: [Storage Design](../../docs/platform/storage-design.md)
- See: [lxc-fstrim.sh](../../snippets/scripts/lxc-fstrim.sh)
