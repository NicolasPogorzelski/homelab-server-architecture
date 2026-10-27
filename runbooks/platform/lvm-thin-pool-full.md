# Runbook: LVM thin pool full (Proxmox host)

- **Use when:** `LvmThinPoolWarning`, `LvmThinPoolCritical` or `LvmThinPoolMetadataCritical`
  fires, a VM shows `status: io-error`, or guests report I/O errors or corrupt binaries.
- **Duration:** 15 minutes to free space; 30-60 minutes more if packages were corrupted.
- **Risk:** at 100 % VMs suspend and LXC writes fail; an apt run in progress leaves partly written
  binaries. Deleting service files to free space is not recoverable.
- **Last exercised:** 2026-04-25, pass (incident: pool at 100 %, vm102 in io-error, corrupt
  `tailscaled` and `bash` on lxc230 and lxc260; recovered to 82.7 %).

The `pve/data` thin pool on the boot disk holds every guest root disk. It allocates chunks on first
write and gets them back only through discard, so a guest's `df` can show free space while the pool
is full. About 60 GiB of the volume group are unallocated, so `lvextend -L +<n>G pve/data` is a
remedy until they are spent; a thin pool cannot shrink afterwards. Background and the corruption pattern: [KE-7](../../docs/platform/known-errors.md#ke-7).

## Preconditions

- Root shell on the Proxmox host (SSH over Tailscale or the console).
- Know which guests are affected:
  ```bash
  lvs -o lv_name,lv_size,data_percent,metadata_percent pve
  qm list; pct list
  journalctl -n 100 --no-pager | grep -i -E 'i/o error|input/output'
  ```

## Steps

1. Stop the writers. If the pool is above the `LvmThinPoolCritical` threshold and rising, stop any
   running `apt-upgrade.yml`, `guest-backup.service` or image pull before repairing anything.
   Check: `lvs pve/data` read twice a minute apart does not rise.

2. Trim every running container from the host. Host-side `fstrim` does not reach LXC filesystems;
   `pct fstrim` does.
   ```bash
   for ctid in $(pct list | awk 'NR>1 && $2=="running" {print $1}'); do
     echo "ct$ctid: $(pct fstrim "$ctid" 2>&1)"
   done
   ```
   The deployed `lxc-fstrim.service` does the same: `systemctl start lxc-fstrim.service`.
   Check: `lvs pve/data` shows a lower `Data%`.

3. Trim the VMs from inside.
   ```bash
   ansible vms -b -m command -a 'fstrim -v /'
   ```
   Check: each host reports bytes trimmed; `lvs pve/data` falls further.

4. Clear apt caches on every running container (re-downloadable, nothing lost).
   ```bash
   for ctid in $(pct list | awk 'NR>1 && $2=="running" {print $1}'); do
     pct exec "$ctid" -- apt-get clean && echo "cleaned $ctid"
   done
   ```
   Then repeat step 2. Check: `Data%` below the `LvmThinPoolWarning` threshold, or at least 15 %
   free.

5. If still too full, find the growth before deleting anything.
   ```bash
   pct exec <ctid> -- du -xsh /var/log /var/lib/docker /var/cache 2>/dev/null
   pct exec <ctid> -- docker system df
   ```
   Images are re-pullable from the pinned compose files, so `docker image prune -a` is reversible by
   `docker compose pull`. Do not delete files a service owns. Repeat step 2 afterwards.
   Check: `Data%` falls.

6. Resume frozen VMs.
   ```bash
   qm resume <vmid>
   ```
   Check: `qm status <vmid>` prints `status: running`.

7. Find corrupted packages on guests that were writing during the overflow.
   ```bash
   pct exec <ctid> -- dpkg --audit
   pct exec <ctid> -- bash -c "dpkg --verify | grep -v '^$'"
   pct exec <ctid> -- file /usr/sbin/tailscaled /bin/bash
   ```
   Check: empty output, and `file` reports `ELF` for both. If bash itself is broken, use
   `pct exec <ctid> -- /bin/sh`.

8. Repair dpkg state and reinstall corrupted packages.
   ```bash
   pct exec <ctid> -- dpkg --configure -a
   pct exec <ctid> -- apt --fix-broken install -y
   pct exec <ctid> -- apt-get install --reinstall <package>
   ```
   Check: step 7 is clean; after reinstalling `tailscale`, `systemctl is-active tailscaled` is
   `active` and `tailscale status` shows the node online.

9. Rerun the interrupted upgrade from lxc250.
   ```bash
   ansible-playbook playbooks/apt-upgrade.yml
   ```
   Check: no failed hosts; the playbook's `dpkg --verify` post-task reports nothing.

## Verification

```bash
lvs -o lv_name,data_percent,metadata_percent pve
journalctl -n 100 --no-pager | grep -ci 'i/o error'      # 0
ansible all -m ping
ansible lxcs -b -m command -a 'dpkg --audit'             # empty on every host
```

In Prometheus, the `lvm` group alerts have resolved and `lvm_thin_pool_data_percent` matches `lvs`.

## Failure modes

| Symptom | Cause | Action |
|---|---|---|
| `qm status` shows `io-error` | VM suspended on a full pool | Free space (steps 2-5), then `qm resume` |
| `apt-get clean` fails in a container | Writes still failing | Step 2 first, then retry |
| `fstrim` inside a container: `Operation not permitted` | FITRIM is refused in unprivileged LXCs | Use `pct fstrim <ctid>` on the host |
| `pct fstrim` reclaims little | Few freed blocks in that container | Step 5 |
| `Exec format error` or `file` says `data` | Binary overwritten mid-write | `apt-get install --reinstall <package>` |
| `dpkg-deb: error: not a Debian format archive` | Truncated `.deb` in the cache | `apt-get clean`, rerun the upgrade |
| `tailscaled` `Needs login` after reinstall | Auth state lost | Re-authenticate with the URL from `tailscale up` |
| Ansible `Failed to create temporary directory` | Guest disk full | Steps 2 and 4 through `pct exec` first |
| `LvmThinMetricsStale` | `lvm-thin-metrics.timer` stopped | `systemctl status lvm-thin-metrics.timer`; read `lvs` directly |
| Pool refills within days | Steady growth (images, logs) | `journalctl -u lxc-fstrim` gives the growth between runs; see [docker-data-root-migration.md](docker-data-root-migration.md) |

## Rollback

- Trimming and `apt-get clean` discard only blocks and files that are already free or
  re-downloadable; there is nothing to roll back.
- Pruned images come back with `docker compose pull` from the pinned compose file.
- A resumed VM can be suspended again with `qm suspend <vmid>`.
- A package reinstall can be reverted by installing the previous version:
  `apt-get install <package>=<version>`.
- Files deleted from a guest are not recoverable except from that guest's vzdump
  ([guest-backup-restore.md](guest-backup-restore.md)).

## Background

Prevention is deployed by the
[`proxmox_host_units`](../../ansible/roles/proxmox_host_units/) role
(`ansible/playbooks/proxmox-host-units.yml`):

- `lxc-fstrim.timer` runs `snippets/scripts/lxc-fstrim.sh` daily with `Persistent=true`. It derives
  the container list from `pct list`, so a new container is covered on creation.
- `lvm-thin-metrics.timer` runs `snippets/scripts/lvm-thin-metrics.sh` as a node_exporter textfile
  collector, because a thin pool has no filesystem and `node_filesystem_*` cannot see it. It
  exports `lvm_thin_pool_data_percent`, `lvm_thin_pool_metadata_percent` and `lvm_vg_free_bytes`;
  thresholds are in `docker/monitoring/prometheus/rules/alert.rules.yml` (group `lvm`).

`apt-upgrade.yml` runs `serial: 1`, cleans the apt cache after each node and verifies binaries with
`dpkg --verify`, so a failure on one node stops the rollout before the next.

Containers cannot trim themselves: the stock `fstrim.timer` carries
`ConditionVirtualization=!container` and the ioctl is refused, and both report healthy. For a
`Type=oneshot` unit, `journalctl -u <unit>` (or the `LAST` column of `systemctl list-timers`) is the
proof that it ran; the unit's timestamps are empty either way. Discard passdown to the SSD itself is
disabled because the HBA does not translate UNMAP; the pool still frees its own chunks.
See [storage-design.md](../../docs/platform/storage-design.md).
