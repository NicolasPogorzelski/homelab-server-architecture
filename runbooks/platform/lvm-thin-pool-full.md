# Runbook: LVM Thin Pool Full (Proxmox)

## Problem

The Proxmox local-lvm thin pool reaches 100% data usage. LXC containers lose write
access (I/O errors), and packages on affected containers may become corrupt.

Observed failure modes (2026-04-25 incident):

- VM102: I/O errors on writes
- LXC230, LXC260: corrupt packages (`tailscaled`, `bash`) — binaries partially overwritten
  during an in-progress apt upgrade when the pool hit 100%

## Preconditions

- SSH access to Proxmox host, or Proxmox WebUI shell
- Understanding that recovery requires freeing pool space before any service can write again

---

## Diagnosis

**Check thin pool usage** (on Proxmox host):

```bash
lvs -o lv_name,data_percent,lv_size,pool_lv
```

Critical threshold: data_percent ≥ 95% warrants immediate action. At 100%, writes fail.

**Identify which LXCs are affected** (I/O errors in journal):

```bash
journalctl -n 50 --no-pager | grep -i "i/o error\|input/output"
```

**Check for corrupt packages on affected LXCs:**

```bash
pct exec <ctid> -- dpkg --verify 2>&1 | grep -v "^$"
```

Non-empty output indicates corrupt binaries.

---

## Recovery

### Step 1 — Free apt cache across all LXCs

Run from the Proxmox host. Repeat for each running LXC:

```bash
for ctid in 200 210 211 220 230 240 250 260; do
    pct exec ${ctid} -- apt-get clean 2>/dev/null && echo "cleaned ${ctid}" || echo "skipped ${ctid}"
done
```

`apt clean` removes downloaded `.deb` files from `/var/cache/apt/archives/`. These are
often the largest reclaim target after an interrupted upgrade.

### Step 2 — Run fstrim on the Proxmox host thin pool

```bash
fstrim -av
```

This tells the block layer to reclaim blocks that LXC filesystems have freed but not yet
returned to the pool. Run from the Proxmox host (not inside LXCs).

Alternatively, use the nsenter approach if the host fstrim does not reach LXC filesystems:

```bash
# Get the init PID of the LXC (replace 230 with ctid)
INIT_PID=$(pct exec 230 -- cat /proc/1/status | grep ^Pid | awk '{print $2}')
nsenter -t ${INIT_PID} -m -- fstrim -av
```

### Step 3 — Reinstall corrupt packages

If `dpkg --verify` reported corrupt binaries on any LXC:

```bash
pct exec <ctid> -- apt-get install --reinstall <package-name>
```

Common affected packages after a pool-full event during apt upgrade:
- `tailscaled` (service will be dead; reinstall restores the binary)
- `bash`, `coreutils` (reinstall immediately — shell may be broken)

Verify the service is back:

```bash
pct exec <ctid> -- systemctl status tailscaled --no-pager
```

---

## Verification

```bash
# Pool usage back below 90%
lvs -o lv_name,data_percent,lv_size,pool_lv

# No I/O errors in recent journal
journalctl -n 50 --no-pager | grep -i "i/o error" | wc -l   # expect 0

# Affected LXCs have no corrupt packages
pct exec <ctid> -- dpkg --verify 2>&1 | grep -v "^$"   # expect empty
```

---

## Failure Modes

| Symptom | Likely Cause | Action |
|---|---|---|
| `apt clean` fails inside LXC | Container filesystem still read-only (pool still full) | Run `fstrim -av` on host first, recheck lvs; retry clean |
| `fstrim` reclaims nothing | LXC filesystems have no freed blocks to return | Delete unused Docker images: `pct exec <ctid> -- docker image prune -af` |
| Pool still at 100% after clean + fstrim | Large log files or Docker volumes consuming space | Check `pct exec <ctid> -- du -sh /var/log /var/lib/docker` |
| `dpkg --verify` shows many corruptions | Binary overwrites mid-upgrade | Reinstall each affected package; if bash is corrupt, use `pct exec <ctid> -- /bin/sh` first |
| Pool fills again within days | Systematic growth (Docker layers, logs) | Review `docker system df` per host; implement log rotation or image cleanup cron |

---

## Prevention

- Run `ansible/playbooks/apt-upgrade.yml` with `serial: 1` — the `dpkg --verify` post-task
  catches binary corruption before it propagates across nodes
- After every apt upgrade run: `snippets/scripts/lxc-fstrim.sh` on the Proxmox host to
  return freed blocks to the pool
- Monitor thin pool usage: add a Prometheus alert rule for `node_filesystem_avail_bytes`
  on the Proxmox host's thin pool mount point

---

## Related

- [Hard Shutdown Recovery](./hard-shutdown-recovery.md) — thin pool overflow can cause the
  high I/O that precedes a forced shutdown
- [Known Errors](../../docs/platform/known-errors.md) — KE-7 documents the binary corruption pattern
