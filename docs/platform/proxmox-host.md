# Proxmox Host

The Proxmox VE hypervisor, the bare-metal layer that runs every VM and LXC, and its
host-level configuration outside any guest: boot ordering, disks, the power schedule, host units
and timers, SSH, storage definitions and guest backup.

## Runtime Characteristics

- OS: Proxmox VE 9.2 on Debian 13 (trixie), default 7.0 kernel line. The 6.17.13 kernel pin was
  released on 2026-10-12 ([KE-14](known-errors.md#ke-14)).
- Tailscale hostname: `server`; address variable `proxmox_host_tailscale_ip`
  (`ansible/inventory/hosts.yml.example`).
- Guests: vm100, vm102, lxc200, lxc210, lxc211, lxc220, lxc230, lxc250, lxc260 (nine).
- Ansible: group `proxmox`, connects as root (see [Ansible Management](#ansible-management)).

## Boot Ordering

Guests start in dependency order after the hypervisor is up, configured per guest as
`startup: order=N,up=M`:

| Startup order | Node(s) | Delay | Role |
|---|---|---|---|
| 1 | vm102 | 30s | Storage; SMB must be reachable before dependents start |
| 2 | lxc200, lxc260 | 20s | Monitoring, PostgreSQL platform |
| 3 | lxc210, lxc211 | 20s | Nextcloud, Paperless |
| 5 | lxc220, lxc230 | 20s | Calibre-Web, OpenWebUI |
| 6 | vm100 | 40s | GPU compute and media |

Order 4 is unused. lxc250 starts on boot (`onboot: yes`); its order
value is not recorded here. vm100 starts last: its media services depend on vm102, and nothing
depends on vm100 at boot.

## pveproxy Tailscale-IP Boot Ordering

`pveproxy` (web UI and API on `:8006`) binds only the host's Tailscale address
(`LISTEN_IP=<tailscale-ip-proxmox-host>` in `/etc/default/pveproxy`), keeping the management UI
off the LAN. The address exists only after `tailscaled` is up, so without a gate pveproxy fails to
bind with `Cannot assign requested address` ([KE-12](known-errors.md#ke-12)).

The `tailscale_boot_gate` role deploys `10-wait-tailscale.conf` for `pveproxy.service`
(`After=`/`Wants=tailscaled.service` and `ExecStartPre=wait-for-tailscale-ip.sh 90`); the unit list
is in `ansible/inventory/group_vars/proxmox.yml`. The host's `node_exporter`, bound to the same
address, carries the gate in its generated unit ([KE-18](known-errors.md#ke-18)).

See: [decision](../decisions/pveproxy-tailscale-boot-ordering.md),
[runbook](../../runbooks/platform/pveproxy-tailscale-boot-race.md).

## Disk Passthrough (vm102)

All ten physical disks are attached to the host. vm102 receives eight by ID as virtio-SCSI
devices (six data disks, the parity disk and aux-pool); the host keeps the boot SSD and aux-disk.
Disk models and IDs are kept offline; the logical topology is in [vm102.md](../nodes/vm102.md).

A guest sees virtio devices, so SMART is readable only on the host; the `smart_metrics` role
exports it here.

## Boot Disk

A 512 GB NVMe disk in the board's M.2 slot (PCIe 3.0 x4), `/dev/disk/by-id/<boot-nvme-by-id>`. It
carries the ESP (`/boot/efi`, partition 2), and on partition 3 the volume group `pve` (476 GiB):
`root` 37.5 GiB, `swap` 8 GiB, the `pve/data` thin pool of 362.5 GiB with 4 GiB metadata, and
about 60 GiB unallocated as a reserve. GRUB boots with shim from the `proxmox-nvme` UEFI entry.

The former boot SSD stays fitted on the LSI SAS2008 HBA (`9:0:0:0`) and carries the `scratch`
pool ([storage definitions](#storage-definitions)). It logged the `DID_SOFT_ERROR` bursts of
[KE-14](known-errors.md#ke-14); identify HBA disks by SCSI address or `by-id`, never by kernel
letter. Procedure: [boot disk replacement](../../runbooks/platform/boot-ssd-replacement.md).

## aux-disk (degraded since 2026-06-25)

aux-disk is mounted at `/mnt/aux-disk` (fstab, `nofail`). It holds the Docker data-roots of the
Docker-in-LXC services, vm100's `jellyfin-data` disk (qcow2) and the PostgreSQL data of lxc260.

On 2026-06-25 it failed with unrecoverable medium errors and would not mount, which put the host
into emergency mode and stopped five containers. All live data was rescued read-only before any
repair. The disk is back in service pending replacement; `nofail` keeps a failed mount out of the
boot path. It is an AHCI device, not behind the HBA; identify it by `by-id`.

See: [KE-13](known-errors.md#ke-13),
[incident](incidents/2026-06-25-aux-disk-failure-and-recovery.md),
[rescue runbook](../../runbooks/storage/aux-disk-failure-rescue.md).

## Host Cron Jobs

The host starts by RTC alarm at a time set per weekday and powers off nightly at 23:30; on days
without a start time it stays off until switched on by hand. The `homelab_schedule` role deploys
the two scripts and the single cron file. Cron is deliberate here: the job powers the host down,
so catch-up semantics would be wrong for it.

| Schedule | User | Command | Purpose |
|---|---|---|---|
| `30 23 * * *` | root | `systemd-cat -t homelab-shutdown ... /usr/local/sbin/homelab-shutdown.sh` | Wait for guarded work, arm the next start, power off |

`journalctl -b -1 -t homelab-shutdown -t homelab-setwake` shows the last night's run;
`homelab-setwake.sh --dry-run` prints the next start without arming anything.

### Start times (homelab-setwake.sh)

Start times live in `homelab_schedule_plans` (role defaults), a list of plans each valid from a
date. The script looks up to 14 days ahead for the next day with a start at least ten minutes
away, using the plan valid on that day, so a new plan takes effect on its date without an apply.
With no start in those 14 days it clears the alarm (`rtcwake -m disable`).

It arms the alarm with `rtcwake -m no -t <unix-timestamp>`, reads `/sys/class/rtc/rtc0/wakealarm`
back, and exits 1 if no alarm is armed or the armed time is more than 60 s off
([KE-26](known-errors.md#ke-26)). The RTC accepts alarms up to one month ahead.

### Shutdown (homelab-shutdown.sh)

Before powering off, the script waits while a guarded unit is active: `guest-backup.service` and
`lxc-fstrim.service` on the host, and on vm102, asked through the QEMU guest agent, the SnapRAID
sync and scrub and `storage-permissions.service`. If work is still running after 180 minutes, or
the next start cannot be armed, it exits 1 and the host stays up, so no work is cut short and the host
never goes off with no way back on.

Source: `ansible/roles/homelab_schedule/templates/`.

## Host Systemd Timers

Every other periodic job on the host is a systemd timer. Schedules are in the owning role's
defaults.

| Timer | Role | Purpose |
|---|---|---|
| `lxc-fstrim.timer` | `proxmox_host_units` | Trim LXC filesystems from the host, returning freed blocks to the `pve/data` thin pool |
| `lvm-thin-metrics.timer` | `proxmox_host_units` | Export thin-pool data and metadata usage to the textfile collector |
| `prometheus-node-exporter-smartmon.timer` | `smart_metrics` | Export SMART attributes per disk (`smartmon.sh`) |
| `guest-backup.timer` | `guest_backup` | Weekly `vzdump` of the nine guests |
| `host-config-backup.timer` | `guest_backup` | Daily archive of the host configuration |

### lxc-fstrim.timer

Containers cannot trim themselves: the stock `fstrim.timer` carries
`ConditionVirtualization=!container`, and an unprivileged container is refused the ioctl. Without
a host-side job, freed blocks stay allocated in the thin pool. `Persistent=true` matters because the
host is off at the scheduled time on many days; the overdue run fires after the next start.
The PostgreSQL restore test depends on this trim reclaiming its throwaway cluster the same morning.

See: [LVM thin pool full](../../runbooks/platform/lvm-thin-pool-full.md).

## netconsole receiver

`netconsole-receiver.service` (template:
`ansible/roles/proxmox_host_units/templates/netconsole-receiver.service.j2`) listens on UDP 6666
and writes what vm100's kernel sends into the host journal (`journalctl -t netconsole-vm100`). It
exists because vm100 froze so completely that its own journal recorded nothing
([KE-20](known-errors.md#ke-20)).

- It binds the host's LAN address, resolved on the node at apply time. netpoll writes frames from
  inside the kernel, and a Tailscale address lives on a TUN device served by a userspace daemon
  that is frozen exactly when the channel is needed.
- The sending side (`netconsole` role on vm100) pins the receiver's MAC; without it the kernel
  broadcasts every frame to the whole segment.
- `lan_guard` admits the netconsole flow from vm100 to the host.

## Ansible Management

The host is an Ansible node in group `proxmox`, connecting as root because root is
its only administrative account. State-changing sweeps reach it only through a named `proxmox`
play ([ansible.md](ansible.md#why-sweeps-target-guests-and-not-all)).

| Artefact | Managed by |
|---|---|
| sshd drop-in `00-hardening.conf` (`PermitRootLogin prohibit-password`) | `ssh_hardening` |
| `node_exporter` unit with textfile and systemd collectors | `node_exporter` |
| `pveproxy` Tailscale boot gate, `wait-for-tailscale-ip.sh` | `tailscale_boot_gate` |
| `lxc-fstrim`, `lvm-thin-metrics`, `smb-mounts-check`, netconsole receiver | `proxmox_host_units` |
| SMART collector (`smartmon.sh` timer and drop-in) | `smart_metrics` |
| Pending-update metric (`apt.sh`) | `apt_metrics` |
| Power schedule scripts and cron file | `homelab_schedule` |
| Guest backup, host-config backup, `platform-restore.sh` | `guest_backup` |
| Kernel panic sysctls | `kernel_panic_policy` |
| LAN nftables table with break-glass paths | `lan_guard` |
| Units masked on the host | `systemd_hygiene` |
| Listener metric, timezone, journald limits | `listener_metrics`, `timezone`, `journald` |
| Syscall auditing (exercise) | `auditd` |
| Guest configs, storage definitions, `/etc/default/pveproxy`, fstab, root's `authorized_keys` | not managed by a role; captured by the daily host-config backup |

Package updates stay outside Ansible: `apt-upgrade.yml` targets `lxcs` and `vms`, because a host
upgrade touches the kernel and the guest stack and belongs in a watched window. Run it as a
transient unit so an SSH session dropped by a `tailscaled` restart cannot kill `dpkg` halfway:

```bash
systemd-run --unit=host-upgrade-<date> /root/host-upgrade.sh   # apt-get dist-upgrade with --force-confold
journalctl -u host-upgrade-<date>
```

Running guests keep the old QEMU and LXC binaries until they are next started.

The host runs no Samba server and sends no mail. The CIFS client packages Proxmox's storage needs
follow normal upgrades. Postfix remains because `proxmox-ve` depends on a mail transport; PVE's
`mail-to-root` notification endpoint is disabled, so nothing leaves the host by SMTP. Alerts reach
a person through Alertmanager only.

## SSH access

`/etc/ssh/sshd_config.d/00-hardening.conf`, rendered by `ssh_hardening`, sets:

| Directive | Value | Why not the guest value |
|---|---|---|
| `PasswordAuthentication` | `no` | Same as the guests |
| `PermitRootLogin` | `prohibit-password` | Root is the only administrative account; `no` would end SSH administration (`group_vars/proxmox.yml`) |

sshd on the host listens on the wildcard address, so SSH works without Tailscale
([decision](../decisions/sshd-listen-address.md)); `lan_guard` admits break-glass SSH from the two
admin workstations only.

The host has no usable out-of-band console: the single GPU is passed through to vm100 with
`x-vga=1`, there is no serial console and no BMC. The Proxmox web shell on `:8006` is the
alternative path. Changes to sshd on this host are made behind a dead-man switch: a transient
`systemd-run --on-active=10min` unit that restores the backed-up config and restarts sshd, armed
first and cancelled only after a fresh connection proves the new configuration.

Verified 2026-08-17: `sshd -T` reports `passwordauthentication no` and `permitrootlogin
without-password`; a login with `PubkeyAuthentication=no` is answered `Permission denied
(publickey)`.

Residual: root's `authorized_keys` is a symlink to `/etc/pve/priv/authorized_keys` and holds four
keys (the host's own `root@server`, two admin workstations, the control node). No role enforces
it; one would have to write through the symlink and keep the host's own key.

## Storage definitions

- `appdata_aux-disk` carries `is_mountpoint 1`, so Proxmox treats the storage as inactive unless a
  filesystem is mounted at the path and cannot write into the empty directory on `pve-root`
  ([KE-7](known-errors.md#ke-7) class). `mkdir 0` on it is deprecated in PVE 9; the replacement is
  `create-base-path 0`.
- No `dir` storage points at an unmounted path on `pve-root`.
- `scratch` is an `lvmthin` storage on the former boot SSD (VG `scratch`, thin pool of 104 GiB)
  for data whose loss costs nothing; its volumes are not overcommitted
  ([decision](../decisions/scratch-pool-on-former-boot-ssd.md)).

## Guest Backup

Weekly `vzdump --mode snapshot` of all nine guests, deployed by the `guest_backup` role and
documented in [guest-backup-restore.md](../../runbooks/platform/guest-backup-restore.md). vm100 is
backed up with its root disk only; its data disk carries `backup=0`. A daily archive of the host
configuration sits beside the guest archives, and `platform-restore.sh` rebuilds the platform from
both ([platform restore](../../runbooks/platform/platform-restore.md)).

The target `/mnt/vzdump` is bound to whichever disk currently holds the role, so a disk change is
an fstab edit. The role refuses to deploy unless the path is a mountpoint whose backing device
differs from root, because an unmounted target would fill the boot SSD with backups of the guests
living on it.

## Failure Impact

There is no second node and no HA; the design is recovery-oriented. All nine guests, every
service, all monitoring and all alerting run on this machine, so a host failure is not reported by
anything on the platform - it is noticed by a person.

| Layer | What its loss takes with it |
|---|---|
| Host OS on `pve-root` | Guest configs in `/etc/pve`, host units, the power schedule |
| `pve/data` thin pool | Every VM and LXC root disk; about 60 GiB of the volume group are unallocated for `lvextend` |
| Boot disk | Both of the above at once; a single consumer NVMe drive without redundancy |
| aux-disk ([KE-13](known-errors.md#ke-13)) | Docker engine state of the Docker-in-LXC services, vm100's data disk, lxc260's database files, and the guest backup target |
| Tailscale identity | Every service address; nodes are reached by MagicDNS name, and the LAN is no fallback for them |

After a total loss of the machine:

- **Survives:** everything on vm102's disks (passed through by ID, readable in another machine),
  including the database dumps; this repository, which reproduces every role-managed artefact.
- **Survives only with aux-disk:** the guest archives and the host-config archive under
  `/mnt/vzdump`; a second host-config copy sits on the boot SSD. No copy exists off site.

Recovery is a fresh Proxmox install followed by
[platform-restore.md](../../runbooks/platform/platform-restore.md): the host configuration first,
then the guests in dependency order.

## Related Documents

- [Operations](operations.md) - boot layers and maintenance routines
- [vm102 - Storage](../nodes/vm102.md)
- [Ansible platform](ansible.md)
- [Guest backup and restore](../../runbooks/platform/guest-backup-restore.md)
- [Remediation plan](remediation-plan.md)
