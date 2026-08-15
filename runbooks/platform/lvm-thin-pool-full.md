# Runbook: LVM thin-pool full (Proxmox)

## Problem

The `local-lvm` thin-pool on the Proxmox host reaches 100% utilization. QEMU VMs enter
`io-error` state and suspend. LXC containers continue running but all writes fail silently -
including apt downloads, which results in corrupt package archives and binary corruption
if an upgrade was in progress at the moment of overflow.

Observed failure modes (2026-04-25 incident):

- VM102: I/O errors on writes
- LXC230, LXC260: corrupt packages (`tailscaled`, `bash`) - binaries partially overwritten
  during an in-progress apt upgrade when the pool hit 100%

## Preconditions

- SSH or console access to the Proxmox host
- All affected VMs/LXCs are identified (`qm status <id>`, `pct status <id>`)

---

## Diagnosis

**Check pool utilization:**

```bash
lvs -o lv_name,lv_size,data_percent,pool_lv
```

If `data_percent` shows `100.00`, the pool is full. At >= 95% warrants immediate action.

**Check for VMs in io-error state:**

```bash
qm status <vmid>
```

Expected output when frozen: `status: io-error`

**Identify which LXCs are affected** (I/O errors in journal):

```bash
journalctl -n 50 --no-pager | grep -i "i/o error\|input/output"
```

**Check LXC disk space (may appear fine despite pool overflow):**

```bash
ansible lxcs -m command -a "df -h /"
```

Note: `df` inside a container reports virtual disk usage, not thin-pool utilization.
A container can show free space while the underlying pool is full.

**Check for corrupt packages on a node:**

```bash
pct exec <ctid> -- dpkg --verify 2>&1 | grep -v "^$"
# Or inside LXC via pct exec, or inside VM via SSH:
dpkg --audit
apt-get check
```

Non-empty output indicates corrupt binaries.

**Check for corrupt binaries:**

```bash
file /usr/sbin/tailscaled   # should be ELF, not "data"
file /bin/bash              # should be ELF, not "data"
```

---

## Recovery

### Step 1 - Free space in the pool

**On all reachable LXCs** (apt cache - largest reclaim target after interrupted upgrade):

```bash
for ctid in 200 210 211 220 230 240 250 260; do
  pct exec ${ctid} -- apt-get clean 2>/dev/null && echo "cleaned ${ctid}" || echo "skipped ${ctid}"
done
```

**fstrim via nsenter from Proxmox host** (fstrim is blocked inside LXCs):

```bash
for ctid in 200 210 211 220 230 240 250 260; do
  PID=$(lxc-info -n "$ctid" 2>/dev/null | awk '/^PID:/{print $2}')
  [ -z "$PID" ] && echo "lxc${ctid}: not running, skipping" && continue
  echo "lxc${ctid} (PID ${PID})..."
  nsenter -t "$PID" --mount -- fstrim -v /
done
```

Alternatively, `fstrim -av` from the Proxmox host reaches thin-pool level directly -
use nsenter only if the host fstrim does not reclaim space on LXC filesystems.

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

### Step 2 - Resume frozen VMs

```bash
qm resume <vmid>
qm status <vmid>   # should return: status: running
```

### Step 3 - Repair corrupt dpkg state on affected LXCs/VMs

```bash
# Check for pending triggers / interrupted installs
pct exec <ctid> -- dpkg --audit

# Configure pending packages
pct exec <ctid> -- dpkg --configure -a

# Fix broken dependencies
pct exec <ctid> -- apt --fix-broken install -y
```

### Step 4 - Reinstall corrupt binaries

If `file <binary>` returns `data` instead of `ELF 64-bit executable`:

```bash
pct exec <ctid> -- apt-get install --reinstall <package>
```

Common victims when upgrade is interrupted mid-write:
- `tailscale` / `tailscaled` (large binary, ~40 MB; service will be dead after reinstall - verify with `systemctl status tailscaled`)
- `bash`, `coreutils` (reinstall immediately - shell may be broken; use `pct exec <ctid> -- /bin/sh` if bash itself is corrupt)
- `login`, `libpam-modules` (upgraded together)

### Step 5 - Re-run the upgrade

After pool space is restored and dpkg state is clean:

```bash
ansible-playbook ansible/playbooks/apt-upgrade.yml
```

---

## Verification

```bash
# All nodes reachable
ansible all -m ping

# Pool utilization back below 90%
lvs -o lv_name,data_percent,lv_size,pool_lv

# No I/O errors in recent journal
journalctl -n 50 --no-pager | grep -i "i/o error" | wc -l   # expect 0

# No broken packages on any node
ansible lxcs -m command -a "dpkg --audit"

# Affected LXCs have no corrupt packages
pct exec <ctid> -- dpkg --verify 2>&1 | grep -v "^$"   # expect empty
```

---

## Failure Modes

| Symptom | Likely Cause | Action |
|---|---|---|
| `qm status <id>` returns `io-error` | VM frozen due to pool overflow | Free pool space, then `qm resume <id>` |
| `No space left on device` during apt | Thin-pool full, writes failing | Run apt clean + fstrim before retrying |
| `apt clean` fails inside LXC | Container filesystem still read-only (pool still full) | Run `fstrim -av` on host first, recheck lvs; retry clean |
| SSH connects but `echo test` returns `Exec format error` | Binary corrupted mid-write | `apt-get install --reinstall <package>` |
| `dpkg-deb: error: not a Debian format archive` | .deb downloaded partially | `apt-get clean` on the node, re-run upgrade |
| `dpkg --verify` shows many corruptions | Binary overwrites mid-upgrade | Reinstall each affected package; if bash is corrupt, use `pct exec <ctid> -- /bin/sh` first |
| tailscaled `Needs login` after reinstall | Auth state lost during reinstall | Re-authenticate via browser login URL in `systemctl status tailscaled` |
| tailscaled `disabled` after reinstall | Unit was not enabled before | `systemctl enable tailscaled` |
| fstrim returns `Operation not permitted` inside LXC | FITRIM ioctl blocked in LXC | Run fstrim via `nsenter` from Proxmox host (see Step 1) |
| `fstrim` reclaims nothing | LXC filesystems have no freed blocks to return | Delete unused Docker images: `pct exec <ctid> -- docker image prune -af` |
| Pool still at 100% after clean + fstrim | Large log files or Docker volumes consuming space | Check `pct exec <ctid> -- du -sh /var/log /var/lib/docker` |
| Ansible `Failed to create temporary directory` on LXC | Disk full, can't write to `~/.ansible/tmp` | Run fstrim + apt clean via `pct exec` first |
| Pool fills again within days | Systematic growth (Docker layers, logs) | Review `docker system df` per host; implement log rotation or image cleanup cron |

---

## Prevention

- **Periodic fstrim:** Automated since 2026-08-10 - `lxc-fstrim.timer` on the Proxmox host runs
  `snippets/scripts/lxc-fstrim.sh` daily at 10:30 with `Persistent=true`. It derives the container
  list from `pct list` rather than a hardcoded array, so a new container is covered on creation;
  the previous array omitted lxc250, which was the fullest container in the fleet. A manual run
  after a large `apt-upgrade` is still reasonable, but nothing depends on remembering it. Note the
  units are hand-deployed - the host is not yet an Ansible node, so they would be lost on a rebuild
  (same debt as the host's `node_exporter`).
- **Serial upgrades:** `apt-upgrade.yml` uses `serial: 1` to prevent simultaneous downloads from spiking pool utilization. The `dpkg --verify` post-task catches binary corruption before it propagates across nodes.
- **apt clean after upgrade:** `apt-upgrade.yml` runs `apt clean` on each node after upgrading.
- **Monitor pool utilization:** Implemented 2026-08-10. The approach previously named here could
  not work - a thin pool is a block-layer object with no filesystem and no mount point, so
  `node_filesystem_*` cannot observe it and the metric that rule would have needed does not exist.
  Instead `lvm-thin-metrics.sh` runs on the Proxmox host every 60 s as a node_exporter textfile
  collector and emits `lvm_thin_pool_data_percent`, `lvm_thin_pool_metadata_percent`,
  `lvm_thin_pool_size_bytes`, `lvm_vg_free_bytes` and `lvm_thin_metrics_scrape_success`. Rules:
  `LvmThinPoolWarning` (>85%, 1 h), `LvmThinPoolCritical` (>90%, 15 min),
  `LvmThinPoolMetadataCritical` (>80%, 15 min) and `LvmThinMetricsStale` (file older than 15 min,
  so a stopped timer cannot leave the other three evaluating a frozen value).
  `lvm_vg_free_bytes` is exported deliberately: it is 0 on this host, which means `lvextend` - the
  first reflex when a pool fills - is not available without shrinking `root`/`swap` or adding a PV.

## Rollback

Mixed, and the split is the point:

- **Freeing space is not reversible.** `fstrim` discards blocks the filesystem has already released,
  so nothing recoverable is lost -- but nothing comes back either.
- **Deleting files to free space is irreversible and has no safety net here.** Nothing on the thin
  pool is backed up as a filesystem. Prefer `pct fstrim` and removing container images over deleting
  anything a service owns.
- **Resuming a frozen VM (step 2) is reversible** -- it can be suspended again.
- **The dpkg repair steps are the ones with a real rollback**, because they reinstall from the
  archive. If a reinstall makes matters worse, the previous package version is still installable by
  version number.

**Abort criterion:** if the pool is above the critical threshold and still rising while you work,
stop repairing and stop the writers first. Repairing dpkg inside a guest whose filesystem is still
being starved produces a second corruption on top of the first.

---

## Notes

- `df -h /` inside a container reports filesystem usage, not thin-pool utilization. Always check the pool directly via `lvs` on the Proxmox host.
- `fstrim` must be run from the Proxmox host for LXCs (`pct fstrim <ctid>`, which enters the
  container's mount namespace and skips bind and read-only mountpoints). Running it inside an LXC
  fails two ways independently: the stock `fstrim.timer` carries `ConditionVirtualization=!container`
  so systemd never starts it, and the ioctl itself is refused with `FITRIM ioctl failed: Operation
  not permitted`. Both failures are silent - `systemctl is-enabled` reports `enabled` and
  `Result=success` is the default of a unit that never ran, so no alert can see this.
- **Proving a unit actually ran:** for `Type=oneshot` without `RemainAfterExit=yes`, systemd
  releases the unit's runtime state once it completes, so `ExecMainStartTimestamp`,
  `InactiveExitTimestamp` and `ActiveEnterTimestamp` are all empty whether it ran or not. They
  are not evidence in either direction. `journalctl -u <unit>` is - `-- No entries --` means never
  ran. For timer-driven units, `systemctl list-timers` also keeps a persistent `LAST` column.
- For VMs, `fstrim` runs normally via SSH since they have full kernel access.
- See: [Storage Design](../../docs/platform/storage-design.md)
- See: [lxc-fstrim.sh](../../snippets/scripts/lxc-fstrim.sh),
  [lxc-fstrim.service](../../snippets/systemd/lxc-fstrim.service),
  [lxc-fstrim.timer](../../snippets/systemd/lxc-fstrim.timer)
- See: [Proxmox host - Host Systemd Timers](../../docs/platform/proxmox-host.md#host-systemd-timers)

---

## Related

- [Hard Shutdown Recovery](./hard-shutdown-recovery.md) - thin pool overflow can cause the high I/O that precedes a forced shutdown
- [Known Errors](../../docs/platform/known-errors.md) - KE-7 documents the binary corruption pattern
