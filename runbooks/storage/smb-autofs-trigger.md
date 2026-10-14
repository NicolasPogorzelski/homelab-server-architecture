# Runbook: SMB mounts on the Proxmox host - automount and boot check

- **Use when:** `smb-mounts-check.service` failed (`SystemdUnitFailed`), a container sees an empty
  directory where a share should be, or a `/mnt/smb/*` entry is added to the host's fstab.
- **Duration:** 10 minutes, plus container restarts.
- **Risk:** low; an fstab edit that breaks parsing affects every mount at the next boot. Removing
  `x-systemd.automount` reintroduces KE-15.
- **Last exercised:** never.

The host mounts `/mnt/smb/*` over CIFS from vm102, a guest it starts itself. A plain fstab entry is
tried once at boot before vm102 exists, fails behind `nofail`, and is never retried; the container
bind then exposes the empty directory on `pve-root`
([KE-15](../../docs/platform/known-errors.md#ke-15)). Two mechanisms prevent this:

- `x-systemd.automount` on every `/mnt/smb/*` entry: the mount is established on first access,
  which comes when Proxmox sets up a container bind, after vm102 is running. No boot ordering can
  place the host's mount after a VM the host itself starts.
- `smb-mounts-check.service`, ordered `After=pve-guests.service`: it touches every `/mnt/smb/*`
  path and exits non-zero if one is not backed by CIFS. node_exporter `--collector.systemd` exports
  the failed unit and `SystemdUnitFailed` alerts on it.

The check script (`snippets/scripts/check-smb-mounts.sh`) and unit
(`snippets/systemd/smb-mounts-check.service`) are deployed by the
[`proxmox_host_units`](../../ansible/roles/proxmox_host_units/) role (`playbooks/proxmox-host-units.yml`).
The fstab entries are not managed by a role.

## Preconditions

- vm102 is running and Samba is active.
- Every `/mnt/smb/*` fstab entry carries `x-systemd.automount`; this prints nothing:
  ```bash
  grep '/mnt/smb/' /etc/fstab | grep -v x-systemd.automount
  ```
- The host's node_exporter runs with `--collector.systemd`; otherwise a failed check raises no
  alert.

## Steps

1. Read the check result.
   ```bash
   systemctl status smb-mounts-check.service --no-pager
   journalctl -u smb-mounts-check.service -b --no-pager
   ```
   Check: `SMB mount check OK`, or a list of paths with their `fstype`.

2. If an entry lacks `x-systemd.automount`: back up fstab first, then add
   `x-systemd.automount,x-systemd.mount-timeout=30` to the entry's options.
   ```bash
   cp -a /etc/fstab /etc/fstab.bak-$(date +%F)
   # edit the entry
   findmnt --verify
   systemctl daemon-reload
   systemctl reset-failed 'mnt-smb-<name>.mount'
   systemctl start 'mnt-smb-<name>.automount'
   ```
   Check: `findmnt --verify` reports no errors; `findmnt -t autofs /mnt/smb/<name>` shows the
   trigger. `daemon-reload` generates the automount unit but does not start it.

3. Bring the mount up.
   ```bash
   ls /mnt/smb/<name> >/dev/null
   findmnt -no FSTYPE,SOURCE /mnt/smb/<name>
   ```
   Check: `cifs //<vm102>/<share>`.

4. Restart every container that binds the path. A bind set up while the host mount was down keeps
   the empty directory.
   ```bash
   grep -l '/mnt/smb/<name>' /etc/pve/lxc/*.conf
   pct reboot <ctid>
   ```
   Check: `pct exec <ctid> -- findmnt -no FSTYPE <mountpoint>` prints `cifs`.

5. Re-run the check.
   ```bash
   systemctl restart smb-mounts-check.service
   ```
   Check: `active (exited)`, `SMB mount check OK: all /mnt/smb/* paths are cifs`.

## Verification

```bash
findmnt -t cifs -R /mnt/smb      # every path, fstype cifs
findmnt -t autofs -R /mnt/smb    # one autofs trigger per path
pct exec <ctid> -- findmnt -o TARGET,FSTYPE,SOURCE <mountpoint>
```

Inside a container, `ext4 /dev/mapper/pve-root[...]` is the KE-15 signature: the bind shows the
directory under the failed mount.

Negative test, proving the check fails loudly:

```bash
mkdir /mnt/smb/zz-test
systemctl restart smb-mounts-check.service          # failed, exit 1
curl -s localhost:9100/metrics | grep 'smb-mounts-check.*failed'   # value 1
rmdir /mnt/smb/zz-test
systemctl reset-failed smb-mounts-check.service && systemctl start smb-mounts-check.service
```

## Failure modes

| Symptom | Cause | Action |
|---|---|---|
| Check failed, path with `fstype=ext4` | CIFS mount for that path is down; bare directory on `pve-root` | Steps 3 and 4 |
| Check failed, `fstype=none` | Stray directory under `/mnt/smb/`, not a mount | Remove it, or add the missing fstab entry |
| Mount unit `failed` after boot, works by hand | Entry lacks `x-systemd.automount` | Step 2 (KE-15) |
| Check fails, no alert | Host node_exporter lacks `--collector.systemd` | Add `--collector.systemd --collector.systemd.unit-exclude='.+\.(automount\|device\|scope\|slice)'`, as the `node_exporter` role does |
| Container sees an empty directory, host mount up | Bind created while the mount was down | `pct reboot <ctid>` |
| Units missing or changed on the host | Drift from the role | Re-run `playbooks/proxmox-host-units.yml` |

## Rollback

Restore fstab from the copy taken in step 2:

```bash
cp -a /etc/fstab.bak-<date> /etc/fstab
systemctl daemon-reload
```

Do not roll back `x-systemd.automount` itself: without it the mount is tried once before vm102
exists and never retried (KE-15). `daemon-reload` does not unmount what is mounted, and a container
whose bind was set up in a broken window still needs `pct reboot <ctid>`. Steps 1, 3 and 5 change no
configuration.

## Background

See [samba.md](../../docs/platform/samba.md) and
[storage-design.md](../../docs/platform/storage-design.md).
