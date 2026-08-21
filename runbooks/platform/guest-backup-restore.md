# Runbook: Guest backup and restore (vzdump)

## Problem

Measured 2026-08-20: the platform had no guest backup at all. `/etc/pve/jobs.cfg` did not exist,
`/etc/cron.d/vzdump` held no entry, and the only artefacts under `/var/lib/vz/dump/` were two log
files from 2026-02-27. Eleven machines, none of them restorable.

The gap lasted because the backups that do exist look like coverage. `pg-backup.sh` and
`mariadb-backup.sh` run nightly and both raise a staleness alert, so the word "backup" was
answered - by two jobs that dump data. Neither of them produces a machine. Ansible produces
configuration, not state: the Paperless document index, Grafana's dashboards and its first-boot
admin password, and Nextcloud's app configuration appear in no role.

The exposure is concentrated rather than spread. Every VM and LXC root disk lives in the `pve/data`
thin pool on a single Samsung 840 EVO with 58,540 power-on hours, attached to the LSI SAS2008 HBA
that produces the unexplained boot-window I/O errors of
[KE-14](../../docs/platform/known-errors.md#ke-14). One disk, eleven machines, no copy.

The clearest evidence that this was understood and unaddressed is
[`lxc250-rebuild.md`](lxc250-rebuild.md): a rebuild runbook exists for the control node precisely
because there is no restore path. This job is what turns that rebuild into a restore.

## Solution

A weekly `vzdump --mode snapshot` of eight guests, written by a systemd timer to a generic
mountpoint that the host binds to whichever disk currently holds the backup role, pruned on a
time-expressed schedule, and exposed to Prometheus through a textfile metric so a silent stop
raises `GuestBackupStale`.

VM100 is excluded deliberately. It is 25 GB of root plus 18 GB of Jellyfin metadata and transcoding
cache, reproducible from its compose stack in minutes, and its media lives on vm102. Including it
would roughly triple a run to protect the guest that needs it least.

### Why the target is a generic path

`BACKUP_DIR` is `/mnt/vzdump`, never a physical disk. The host binds the current target onto
that path, so changing disks is an fstab edit and nothing else. Two reasons this matters here
beyond tidiness:

- The backup target is expected to change. The interim target is the auxiliary disk; replacement
  hardware is on order. A path baked into a script would make that migration a code change with a
  review, on the day somebody is already handling disks.
- The real disk label stays out of a public repository, the same reason `/etc/snapraid.conf`'s
  device lines remain hand-written.

## Preconditions

The role asserts these and refuses to deploy if they are missing.

1. **The Proxmox host is in the Ansible inventory** as the `proxmox` group. `vzdump` is a
   host-level tool, so this playbook targets the hypervisor and nothing else. Until that group
   exists, `ansible-playbook` prints `skipping: no hosts matched` and exits 0 - reporting success
   while doing nothing.
2. **`/mnt/vzdump` is a mountpoint**, and its backing device is not the root device. Both
   conditions are checked, because a bind mount of a local directory satisfies the first and fails
   the purpose. If the backup disk does not mount, the path still exists as an empty directory on
   `pve-root` and `vzdump` would write ten gigabytes a week into the thin pool on the boot SSD -
   filling the disk that carries every guest, in order to back up those guests. That is the KE-7
   failure class, and it is why the role asserts the mount instead of creating the directory.
3. **At least 25 GB free** on the target - two full runs. `vzdump` prunes only after a successful
   write, so a target with no room produces a failed run rather than a rotated one, and the newest
   backup stays whatever it happened to be.
4. **Every passthrough disk on a VM carries `backup=0`.** The role cannot assert this one, and it is
   the precondition with the largest blast radius. For a VM, `vzdump` backs up *all* attached
   disks; it is the guest config, not the backup job, that decides what is in scope. vm102 has
   seven `by-id` passthrough disks - the SnapRAID array - and without `backup=0` a run announces
   `0% (519.4 MiB of 55.5 TiB)` and writes until the target is full. Measured 2026-08-21 on the
   first real run: 90 GB in fifteen minutes before it was interrupted. Audit with
   `qm config <vmid> | grep -E '^(scsi|virtio|sata)[0-9]'` - every line that names a
   `/dev/disk/by-id/` path must end in `backup=0`. The check belongs here rather than in the role
   because it lives in the guest's config, which a VM rebuild resets and no Ansible task owns.
   Verified after setting it: the run reports `include disk 'scsi0' ... 16G` followed by seven
   `exclude disk ... (backup=no)` lines, and finishes in 20 s with a 1.67 GB archive.

### Binding the target (one time, and again on every disk change)

The host is the node being changed, so this is done there directly:

```
# Identify the disk by ID, never by kernel letter. sd* names follow probe order
# and change between boots - the boot SSD was documented as sdc for a month and
# enumerated as sda on 2026-08-13.
ls -l /dev/disk/by-id/ | grep -v part

mkdir -p /mnt/vzdump
```

Add to `/etc/fstab`, substituting the real identifier:

```
/dev/disk/by-id/<disk-id>  /mnt/vzdump  ext4  defaults,nofail,noatime  0  2
```

`nofail` keeps a missing disk out of emergency mode; the role's mount assert is what turns that
tolerated absence into a visible refusal instead of a silent write to the wrong disk.

For an interim target that is a directory on an already-mounted disk, bind it instead:

```
/mnt/<existing-mount>/vzdump  /mnt/vzdump  none  bind,nofail  0  0
```

Note the assert compares backing devices, so a bind whose source lives on the root filesystem is
refused. That is intended.

## Deployment

```
cd ~/git/homelab-server-architecture/ansible
ansible-playbook playbooks/guest-backup.yml --check --diff
ansible-playbook playbooks/guest-backup.yml
```

First run, on demand rather than waiting a week for the timer:

```
systemctl start guest-backup.service
journalctl -u guest-backup.service -f
```

## Verification

Run all five. The first four prove the mechanism; only the fifth proves a backup.

```
# 1. The timer is scheduled and will catch up after a missed slot
systemctl list-timers guest-backup.timer
systemctl cat guest-backup.timer | grep Persistent

# 2. The run finished and every guest is present
journalctl -u guest-backup.service -b | tail -40
ls -la /mnt/vzdump/

# 3. The archives are internally readable (structure, not content)
# Both extensions, and this is not pedantry: containers produce .tar.zst and VMs
# produce .vma.zst. A loop over *.tar.zst alone walks every container, reports OK,
# and silently covers no VM at all.
for f in /mnt/vzdump/*.zst; do echo -n "$(basename $f): "; zstd -t "$f" 2>/dev/null && echo OK || echo FAILED; done

# 4. The metric reaches Prometheus
curl -s "http://<lxc200>:9090/api/v1/query?query=guest_backup_last_run_timestamp_seconds"
curl -s "http://<lxc200>:9090/api/v1/query?query=guest_backup_failed_guests"

# 5. A restore actually works - see below
```

### Recorded verification runs

An archive that has never been restored from is the same fiction as an untested backup. Restore one
guest into a throwaway ID once a quarter and record the date here, exactly as
[`pg-restore.md`](../database/pg-restore.md) does.

| Date | Guest restored | Result | Notes |
|---|---|---|---|
| 2026-08-21 | lxc260 into ID 999 | Pass | Restore 10 s, 1.4 GiB, pool 82.85 -> 85.14 % and back on teardown. Never started: verified through `pct mount`. Debian 12 present, PostgreSQL 15 cluster with `global/pg_control`, 26,721 files, `postgresql.conf` / `pg_hba.conf` / `node_exporter.service` byte-identical to the live node. All seven archives passed `zstd -t` beforehand, and lxc250's passed a full `tar -tf` walk (154,159 entries, rc=0) holding `hosts.yml`, `.vault_pass` and `id_ed25519`. lxc260 was chosen over lxc250 because the thin pool is the only storage that accepts a container rootfs and the smaller archive keeps the excursion below the critical threshold. |

## Restore

Restoring to a new ID is the safe form and the one to use for a test. It leaves the running
guest untouched, so a failed restore costs nothing.

```
# List what is available
ls -la /mnt/vzdump/

# local-lvm is the only option, and that constrains which guest to test.
# `pvesm status --content rootdir` returns the thin pool alone: `local` does not
# carry the rootdir content type and `appdata_aux-disk` is images-only, so a
# restore there is refused with "storage does not support container directories".
# The pool sits above 82 % with vg_free at zero, so pick the SMALLEST archive
# rather than the most important one - restoring lxc260 (1.4 GiB) reaches 85.1 %,
# restoring lxc250 (5.25 GiB) reaches 91 % and crosses the critical threshold.
# The mechanism is generic; the guest is a sample, not the subject.
pct restore 999 /mnt/vzdump/vzdump-lxc-260-<timestamp>.tar.zst \
  --storage local-lvm --unprivileged 1

# Do NOT start it. A restored guest is a byte-identical clone down to its
# Tailscale node key and hostname, so booting it on the network makes two nodes
# claim one identity - a live outage on the original. `pct mount` gives the
# filesystem without running a single process inside the container, which is
# enough to answer the question the test asks.
pct mount 999
R=/var/lib/lxc/999/rootfs
grep PRETTY_NAME $R/etc/os-release
ls $R/var/lib/postgresql/15/main/global/pg_control

# Fidelity, not just presence: compare bytes against the live node. Config files
# do not change between the backup and the test, so a mismatch is a real fault.
for f in /etc/postgresql/15/main/postgresql.conf /etc/systemd/system/node_exporter.service; do
  a=$(md5sum "$R$f" | cut -d' ' -f1)
  b=$(pct exec 260 -- md5sum "$f" | cut -d' ' -f1)
  [ "$a" = "$b" ] && echo "MATCH $f" || echo "DIFFER $f"
done

# Tear down. destroy releases the thin-pool space immediately; nothing waits on
# fstrim because the volume itself is removed.
pct unmount 999 && pct destroy 999
```

Booting the clone is a separate question with its own risk, and it is not what
this test is for. If it is ever asked, break the link first
(`pct set 999 --net0 name=eth0,bridge=vmbr0,link_down=1`) and reach it through
`pct exec`, which needs no network.

**Check thin-pool headroom before restoring.** `pve/data` was at 82.78 % on 2026-08-20 with
`lvm_vg_free_bytes` at zero, so a restore consumes space that cannot be replaced by `lvextend`.
A restored guest also holds blocks a container cannot `fstrim` itself; the host's `lxc-fstrim.timer`
at 10:30 reclaims them, which is the same dependency the monthly PostgreSQL restore test relies on.

Restoring over the original is the recovery case, not the test case:

```
pct stop 260
pct restore 260 /mnt/vzdump/vzdump-lxc-260-<timestamp>.tar.zst --force --storage local-lvm
pct start 260
```

`--force` destroys the existing guest first. There is no undo.

## Failure

| Symptom | Cause | Action |
|---|---|---|
| `400 Parameter verification failed. storage: missing property required by 'notes-template'` | `--notes-template` was passed alongside `--dumpdir` | Remove it. The option is declared `requires => 'storage'` in `PVE/VZDump/Common.pm`, so it fails verification before any guest is touched - every guest, deterministically. `protected` carries the same requirement |
| `0% (... of NN TiB)`, target filling | A VM's passthrough disks lack `backup=0` | Precondition 4 above. `vzdump` backs up every disk attached to a VM; the guest config is what scopes the job |
| `tar: ./<path>: Cannot open: Permission denied`, one container only | A directory inside the rootfs sits outside the container's UID map | Unprivileged containers are archived through `lxc-usernsexec -m u:0:100000:65536`. A path owned outside that range is unreadable, `tar` exits non-zero and the guest fails while the rest of the run continues. Seen on lxc220 (`/opt/calibreweb`), which is the node whose UID mapping is already documented tech debt |
| `is not a mountpoint - refusing` | Backup disk did not mount | `findmnt /mnt/vzdump`; check the fstab entry resolves by-id, not by kernel letter |
| `resolves to the root device` | The bind source is on `pve-root` | The target must be a different physical disk; a backup sharing the failure domain is not one |
| `vzdump <id> exited 255`, others fine | One guest failed; the run continued by design | `journalctl -u guest-backup.service`; usually a snapshot that could not be taken because the storage is full |
| Run fails, target has space | Thin pool has no room for the snapshot | `lvs`; the snapshot lives in `pve/data`, not on the backup disk |
| `GuestBackupMetricsMissing` | Job never deployed, or collector stopped | The other backup rules read green in this state - check the unit exists at all |
| Timer exists, never fires | Host asleep at the calendar slot | Expected; `Persistent=true` catches up at boot. Confirm with `systemctl list-timers` |

## Rollback

The role adds files and changes no existing state, so removal is complete:

```
systemctl disable --now guest-backup.timer
rm /etc/systemd/system/guest-backup.{service,timer}
rm /usr/local/sbin/guest-backup.sh
rm /var/lib/node_exporter/textfile_collector/guest-backup.prom
systemctl daemon-reload
```

Existing archives under `/mnt/vzdump/` are left alone - deleting the backups is not part of
rolling back the job that wrote them. Remove the `backup` rule group from `alert.rules.yml` in the
same pass, or `GuestBackupMetricsMissing` will correctly report that nothing is reporting.

## Known limitations

- **The alerts share a failure domain with what they guard.** Prometheus runs on lxc200, on the host
  these backups protect. If that host is down, there is no scrape, and `Persistent=true` refreshes
  the timestamp before Prometheus returns. The rules mean "not more than 10 days of uptime without a
  backup". Same class as `PostgreSQLBackupStale` and as the host `node_exporter` whose own failure
  is what stopped the host reporting. The general fix is the external heartbeat in
  [`remediation-plan.md`](../../docs/platform/remediation-plan.md) Tier 4.
- **A snapshot backup of a running database is crash-consistent, not transaction-consistent.** For
  lxc260 and lxc210 the authoritative copies remain `pg-backup.sh` and `mariadb-backup.sh`; this job
  restores the machine, those restore the data. Restore the guest, then replay the dump.
- **One site.** Until the target is a disk that leaves the flat, this protects against disk and
  guest loss, not against fire, theft or ransomware reaching the mount.

## Related

- [`lxc250-rebuild.md`](lxc250-rebuild.md) - the procedure this job is meant to replace
- [`pg-restore.md`](../database/pg-restore.md) - the recorded-date discipline copied here
- [`lvm-thin-pool-full.md`](lvm-thin-pool-full.md) - what a restore can trigger
- [`known-errors.md#ke-14`](../../docs/platform/known-errors.md#ke-14) - the disk carrying every guest
