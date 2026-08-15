# Runbook: SMB mounts on the Proxmox host — automount + boot verification

## Problem

The Proxmox host mounts `/mnt/smb/*` over CIFS **from VM102 — a guest of that same host.** At boot
the host therefore tries to reach an SMB server it has not started yet. A plain fstab entry fails
once, `nofail` lets the boot proceed, and systemd never retries: the mount unit stays `failed`
forever, the container bind that depends on it exposes the empty directory underneath (on
`pve-root`), and the service inside the container fails silently.

That is not hypothetical. It is [KE-15](../../docs/platform/known-errors.md#ke-15): one fstab line
missing one option, one month of failure, ~20 000 failed service runs, nothing alerted.

## The two mechanisms that fix it

**1. `x-systemd.automount` on every `/mnt/smb/*` fstab entry.** The mount is then established
*lazily, on first access*, rather than once at boot. The first access happens when Proxmox sets up
a container's bind mount — by which time VM102 has been running for minutes. This is the only
mechanism that can work, because no boot ordering can put the host's mount after a VM the host
itself starts.

**2. `smb-mounts-check.service` — verification that fails loudly.** Ordered `After=pve-guests.service`,
it forces every automount to resolve and exits non-zero if any `/mnt/smb/*` path is not backed by
CIFS. `node_exporter --collector.systemd` exports the failed unit and the `SystemdUnitFailed` rule
alerts on it.

> **Historical note.** This runbook previously described `trigger-smb.mounts.service`, which could
> not work by construction: it ran `After=network-online.target` — reached *before* `pve-guests`
> starts VM102 (measured on the 2026-07-14 boot: trigger at 12:16:15, VM102 started at 12:16:23) —
> so it poked automounts whose server did not yet exist. And it swallowed every error (`|| true`),
> so it reported success unconditionally. It was removed on 2026-07-14 and replaced by the check
> above.

## Precondition

- VM102 is running and Samba is active
- Every `/mnt/smb/*` entry in the host's `/etc/fstab` carries `x-systemd.automount`
- The host's `node_exporter` runs with `--collector.systemd` (otherwise a failing check unit
  raises no alert — see the note under Failure)

Audit the fstab requirement in one line — it must print nothing:

```bash
grep '/mnt/smb/' /etc/fstab | grep -v x-systemd.automount
```

## Implementation (Proxmox host)

Sources of truth for this runbook:

- Script: [check-smb-mounts.sh](../../snippets/scripts/check-smb-mounts.sh)
- Unit: [smb-mounts-check.service](../../snippets/systemd/smb-mounts-check.service)

```bash
install -m 0755 -o root -g root check-smb-mounts.sh /usr/local/sbin/check-smb-mounts.sh
install -m 0644 -o root -g root smb-mounts-check.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now smb-mounts-check.service
```

Adding `x-systemd.automount` to an entry that lacks it:

```bash
cp -a /etc/fstab /etc/fstab.bak-$(date +%F)
# add `x-systemd.automount,x-systemd.mount-timeout=30` to the options of the entry
systemctl daemon-reload
systemctl reset-failed 'mnt-smb-<name>.mount'
systemctl start 'mnt-smb-<name>.automount'
```

A container whose bind was set up while the host mount was down keeps pointing at the empty
directory. It must be restarted afterwards: `pct reboot <ctid>`.

## Verification

```bash
systemctl status smb-mounts-check.service --no-pager   # expect: active (exited), "SMB mount check OK"
findmnt -t cifs /mnt/smb/                              # expect: every path, fstype cifs
findmnt -t autofs /mnt/smb/                            # expect: an autofs trigger per path
```

Inside a container that binds one of these paths:

```bash
pct exec <ctid> -- findmnt /<mountpoint> -o TARGET,FSTYPE,SOURCE   # expect cifs, NOT ext4
```

`ext4 /dev/mapper/pve-root[...]` inside the container is the KE-15 signature: the bind is showing
the empty directory under the failed mount.

Negative test (proves the check is not another silent guard):

```bash
mkdir /mnt/smb/zz-test
systemctl restart smb-mounts-check.service    # expect: failed, exit 1
curl -s localhost:9100/metrics | grep 'smb-mounts-check.*failed'   # expect: ... 1
rmdir /mnt/smb/zz-test
systemctl reset-failed smb-mounts-check.service && systemctl start smb-mounts-check.service
```

## Failure

| Symptom | Cause | Action |
|---|---|---|
| `smb-mounts-check.service` failed, log names a path with `fstype=ext4` | The CIFS mount for that path is down; the bare directory on `pve-root` is showing | `mount /mnt/smb/<name>`, then `pct reboot <ctid>` for every container binding it |
| `smb-mounts-check.service` failed, `fstype=none` | Path exists under `/mnt/smb/` but is not a mount at all (e.g. a stray directory) | Remove the directory, or add the missing fstab entry |
| Mount unit `failed` after boot, works when mounted by hand | The fstab entry lacks `x-systemd.automount` — it was tried once, before VM102 existed | Add the option (see above). This was KE-15 |
| Check unit fails but no alert arrives | The host's `node_exporter` lacks `--collector.systemd`, so `node_systemd_unit_state` is never exported for this host | Add `--collector.systemd --collector.systemd.unit-exclude='.+\.(automount\|device\|scope\|slice)'` to its `ExecStart`, mirroring the `node_exporter` Ansible role |
| Container still sees an empty directory although the host mount is up | The bind was created while the mount was down; it does not heal by itself | `pct reboot <ctid>` |

## Rollback

The procedure takes its own backup (`cp -a /etc/fstab /etc/fstab.bak-<date>`), and that copy is the
rollback:

```bash
cp -a /etc/fstab.bak-<date> /etc/fstab
systemctl daemon-reload
```

The unit installation is equally reversible:

```bash
systemctl disable --now smb-mounts-check.service
rm /etc/systemd/system/smb-mounts-check.service /usr/local/sbin/check-smb-mounts.sh
systemctl daemon-reload
```

**But rolling back `x-systemd.automount` reintroduces KE-15**, in which the mount is attempted once
at boot against a guest the host has not started yet, fails, and is never retried -- silently, for a
month. If the option appears to cause a problem, diagnose the mount; do not remove the retry.

**Note the asymmetry:** `daemon-reload` after restoring fstab does not unmount what is already
mounted, and a container whose bind was set up during the broken window still needs
`pct reboot <ctid>`. Reverting a configuration does not revert the state it produced.

---
## Related

- [KE-15 — calibre-import dead for a month](../../docs/platform/known-errors.md#ke-15)
- [Samba architecture](../../docs/platform/samba.md)
- [Storage design](../../docs/platform/storage-design.md)
