# Proxmox Host

This document describes the Proxmox VE hypervisor - the bare-metal layer that runs all VMs and LXCs.

Unlike the node docs in `docs/nodes/`, this covers host-level configuration that lives outside any container: cron jobs, deployed scripts, disk passthrough, and boot ordering.

## Runtime Characteristics

- OS: Proxmox VE (Debian-based)
- Tailscale hostname: server
- Tailscale variable: `proxmox_host_tailscale_ip` (see `ansible/inventory/hosts.yml.example`)
- Managed nodes: VM100, VM102, LXC200-LXC260

## Boot Ordering

VMs and LXCs start in dependency order after the hypervisor is up:

| Startup order | Node(s) | Delay | Role |
|---|---|---|---|
| 1 | VM102 | 30s | Storage (SMB must be reachable before dependents) |
| 2 | LXC200, LXC260 | 20s | Monitoring, PostgreSQL platform |
| 3 | LXC210, LXC211 | 20s | Nextcloud, Paperless |
| 4 | LXC240 | 20s | Vaultwarden |
| 5 | LXC220, LXC230 | 20s | Calibre-Web, OpenWebUI |
| 6 | VM100 | 40s | Compute / GPU media |

Startup order and delays are configured per VM/LXC in the Proxmox guest config (`startup: order=N,up=M`). VM102 must be fully up (SMB reachable) before storage-dependent nodes start, to avoid mount failures. VM100 (compute/GPU) starts last - its media services depend on VM102 storage but nothing depends on VM100 at boot.

## pveproxy Tailscale-IP Boot Ordering

`pveproxy` (the web UI / API proxy on `:8006`) binds only the host Tailscale IP
(`/etc/default/pveproxy` -> `LISTEN_IP=<tailscale-ip-proxmox-host>`) to keep the
management UI on the tailnet, off the LAN. Because that IP only exists after
`tailscaled` starts, pveproxy lost a boot race and failed to bind with `Cannot
assign requested address` until manually restarted (2026-06-25).

Gated via a systemd drop-in
`/etc/systemd/system/pveproxy.service.d/wait-tailscale.conf` (`After=`/`Wants=tailscaled.service`
+ an `ExecStartPre` poll until the Tailscale IP is on `tailscale0`). Same fault
class and pattern as the PostgreSQL Tailscale-IP boot race on LXC260.

See: [KE-12](./known-errors.md#ke-12),
[ADR pveproxy-tailscale-boot-ordering](../decisions/pveproxy-tailscale-boot-ordering.md),
[runbook](../../runbooks/platform/pveproxy-tailscale-boot-race.md).

`node_exporter` on the host has the same dependency and, since 2026-07-14, the same bind
(`--web.listen-address=<tailscale-ip-proxmox-host>:9100`) - but it had no gate, so it failed at
every boot from that change until 2026-07-28. Gated the same way:
`/etc/systemd/system/node_exporter.service.d/wait-tailscale.conf` with
`ExecStartPre=/usr/local/bin/wait-for-tailscale-ip.sh 90` and `RestartSec=5`. The script is a
verbatim copy of the one the `postgresql_boot_order` role deploys on LXC260; it derives the address
via `tailscale ip -4` instead of hard-coding it, which is why it could be reused unchanged.

Both the script and the drop-in are hand-deployed - the host is not an Ansible-managed node, so
they will be lost on a host rebuild. Note also that the older `pveproxy` drop-in still carries its
Tailscale IP inline rather than calling the shared script; folding it into the same pattern is a
small cleanup for the next host pass.

See: [KE-18](./known-errors.md#ke-18).

## Disk Passthrough (VM102)

Data and parity disks for VM102 are passed through by ID from the host:

```
/dev/disk/by-id/<disk-id>
```

Exact disk models and IDs are documented offline. See [VM102 node doc](../nodes/vm102.md) for the logical topology.

All nine physical disks are attached to the host. VM102 sees seven of them as virtio-SCSI devices
(five data disks, the parity disk and the pool's auxiliary disk); the host keeps the remaining two,
the boot SSD and the application-data auxiliary disk. Corrected 2026-08-17 - this said six, as did
`CLAUDE.md`. Either way the operative half is unchanged: a guest sees virtio devices, so SMART is
readable only on the host and any SMART monitoring must run here, not on VM102.

## Boot SSD - Intermittent I/O Errors (KE-14)

The boot SSD does not hang off the SATA controller. It is attached to an LSI SAS2008 HBA
(`mpt2sas`, firmware `20.00.07.00`, `phy(3)`, SCSI address `9:0:0:0`). It carries `/boot/efi`,
`pve-root` and the whole `pve-data` thin pool - every VM and LXC root disk.

**Identify it by `9:0:0:0` or `by-id`, never by its kernel letter.** `sd*` names follow probe
order and change between boots - this disk was documented as `sdc` through July 2026 and came up
as `sda` on 2026-08-13. `lsblk -dno NAME,TRAN` distinguishes it reliably: the boot SSD reports
`sas`, the two auxiliary disks `sata`.

On some boots the kernel logs a burst of `DID_SOFT_ERROR` read failures against it, always
within the boot window and never afterwards. These are **transport-layer faults, not media
failures**: the drive's SMART error log is empty and every media counter is zero. Root cause is
unconfirmed; the leading hypothesis is a sagging 12 V rail under peak boot load. No filesystem
damage has occurred.

**Still live:** the 2026-08-13 boot produced two such lines at boot + 3 min (`cmd_age=29s`) while
the preceding boot was clean - the documented on/off pattern, not a trend. None of the four
physical verification steps has been performed.

Full analysis and the outstanding physical verification steps: [KE-14](./known-errors.md#ke-14).

## aux-disk Auxiliary Disk (Failed 2026-06-25)

aux-disk is a host auxiliary disk mounted at `/mnt/aux-disk` (fstab entry with
`nofail`). It backs the Docker data-root of the Docker-in-LXC services (per the
"Adding a New Service" checklist) and stores VM100's `jellyfin-data` `.raw` image.

On 2026-06-25 it failed with unrecoverable medium errors and would not mount - the
original cause of the emergency-mode lockout and of LXC200/211/220/230/260 failing
to start. All live data was rescued read-only before any repair attempt. The disk is
**back in service under protest**, carrying those five data-roots again, pending a
replacement; the `nofail` entry keeps the boot out of emergency mode. Its SMART
attributes have been static since 2026-07-09 (verified 2026-08-13) - not safe, but
not accelerating either, which is why replacement is a planned task. It is an AHCI
device, not behind the HBA; identify it by `by-id`, not by kernel letter. See
[KE-13](./known-errors.md#ke-13).

See: [KE-13](./known-errors.md#ke-13-aux-disk-physical-disk-failure-medium-errors),
[incident write-up](./incidents/2026-06-25-aux-disk-failure-and-recovery.md),
[aux-disk rescue runbook](../../runbooks/storage/aux-disk-failure-rescue.md).

## Host Cron Jobs

Deployed as `/etc/cron.d/homelab-schedule`, currently managed manually (deployed 2026-05-23). A `homelab_schedule` Ansible role exists to codify these scripts + cron file but has not yet been applied to the live host (see [Ansible platform](./ansible.md)).

| Schedule | User | Script | Purpose |
|---|---|---|---|
| `45 0 * * *` | root | `/usr/local/sbin/homelab-setwake.sh` | Program RTC wakeup alarm for tomorrow before shutdown |
| `0 1 * * *` | root | `/usr/local/sbin/homelab-shutdown.sh` | Scheduled nightly shutdown (2h buffer after SnapRAID sync at 23:00 on VM102) |

### Wake Times (homelab-setwake.sh)

The script programs the RTC alarm via `rtcwake -m no -t <unix-timestamp>` based on the next day:

- **Tuesday, Wednesday** (day 2 or 3): wake at 16:00
- **All other days**: wake at 07:30

Source: `scripts/homelab-setwake.sh` - deployed to `/usr/local/sbin/homelab-setwake.sh`.

### Shutdown (homelab-shutdown.sh)

Runs `shutdown -h now`. The 01:00 schedule gives a 2-hour buffer after the SnapRAID sync on VM102 (23:00 daily) - the order is: sync completes -> host shuts down -> RTC wakes host at configured time.

Source: `scripts/homelab-shutdown.sh` - deployed to `/usr/local/sbin/homelab-shutdown.sh`.

## Host Systemd Timers

Homelab-authored periodic jobs on the host are systemd timers, not cron entries. The power
schedule above is the deliberate exception - it is the job that powers the host down, so it cannot
depend on the host being up, and catch-up semantics would be actively wrong for a shutdown trigger.

| Timer | Schedule | Unit | Purpose |
|---|---|---|---|
| `lxc-fstrim.timer` | `*-*-* 10:30`, `Persistent=true` | `/usr/local/sbin/lxc-fstrim.sh` | Return blocks freed inside LXC containers to the `pve/data` thin pool |
| `lvm-thin-metrics.timer` | every 60 s, no catch-up | `/usr/local/sbin/lvm-thin-metrics.sh` | Export thin-pool utilisation to the node_exporter textfile collector |
| `node-exporter-smarttext.timer` | every 60 s | `/usr/local/sbin/node-exporter-smarttext.sh` | Export SMART health + temperature per disk (pre-existing, hand-deployed) |

### lxc-fstrim.timer (added 2026-08-10)

Containers cannot trim themselves: the stock `fstrim.timer` carries
`ConditionVirtualization=!container` so systemd never starts it there, and an unprivileged
container is refused the ioctl regardless. Without a host-side job, freed blocks stay allocated in
the thin pool forever - which is how `pve/data` reached 92.55% with only 23 GiB actually in use.

`Persistent=true` is load-bearing. `homelab-setwake.sh` wakes the host at 07:30 on most days but at
**16:00 on Tuesday and Wednesday**, so no single wall-clock time is inside the awake window every
day. On those two days the host is still off at 10:30 and the overdue run fires just after the
16:00 boot. Without catch-up the job would silently never run on Tue/Wed - the same defect that
cost the PostgreSQL backups two months.

Source: `snippets/scripts/lxc-fstrim.sh`, `snippets/systemd/lxc-fstrim.service`,
`snippets/systemd/lxc-fstrim.timer`. Hand-deployed - the host is not an Ansible node, so these
would be lost on a rebuild, the same debt as the host's `node_exporter`.

See: [LVM thin pool full](../../runbooks/platform/lvm-thin-pool-full.md).

## netconsole receiver (added 2026-08-17)

`netconsole-receiver.service` listens on UDP 6666 and writes what vm100's kernel sends into the
host journal, readable with `journalctl -t netconsole-vm100`. It exists because of
[KE-20](known-errors.md#ke-20): vm100 froze so completely that its own journal recorded nothing,
not even the line systemd emits before stopping a mount unit. A log that has to be written to the
frozen machine's disk is no use in that failure; one that leaves the machine as a UDP frame is.

Two properties are deliberate and both are exceptions worth stating rather than discovering later:

- It binds the host's LAN address, not the Tailscale one. netpoll writes frames from inside the
  kernel, and a Tailscale address lives on a TUN device served by a userspace daemon - frozen along
  with everything else exactly when this channel is needed. The platform binding rule does not fit
  a transport the kernel must reach without help.
- The sending side pins the receiver's MAC. Omitting it is legal and makes the kernel broadcast
  every frame to the whole segment, including the untrusted televisions.

Source: `snippets/systemd/netconsole-receiver.service`. Hand-deployed, so it joins the list above of
units a rebuild would lose. The sending half is Ansible-managed (`netconsole` role on vm100), which
is the asymmetry the host adoption would remove.

## Ansible Management

The Proxmox host is not yet a fully managed Ansible node. A `homelab_schedule` role exists to manage the power-schedule scripts and cron file, but it has not yet been applied - those are currently deployed manually. Full host management (package updates) is not implemented.

SSH hardening was applied by hand on 2026-08-17 after an audit measured `permitrootlogin yes` with `passwordauthentication yes` on this node - see the section below. It is correct now and maintained by nothing, which is the same debt as the hand-deployed units above and closes with the same adoption.

To run the schedule role against the host:

```bash
ansible-playbook playbooks/homelab-schedule.yml
```

Requires: the `proxmox` group in `hosts.yml` to be populated with the host's Tailscale IP. Note
the failure mode if it is not, verified 2026-08-17: the real inventory has no such group, so this
command matches no host, prints `skipping: no hosts matched` and exits 0. It reports success while
doing nothing. `hosts.yml.example` does carry the group, which makes the example look like the
live state and hides the gap. The same applies to `onboarding.yml`, whose `lxc-test` group has
never existed.

See: [Ansible platform](./ansible.md)

## SSH access (hardened by hand 2026-08-17)

Until this date the hypervisor accepted `PasswordAuthentication` and `PermitRootLogin yes`, on
`0.0.0.0:22`. Neither had ever been set deliberately - `PermitRootLogin yes` was explicit in
`sshd_config`, password authentication was sshd's default because the directive was commented out.
The cause is the one recorded throughout this file: the host is in no inventory group, so
`ssh-hardening.yml` (`hosts: all`) has never run against it.

Now `/etc/ssh/sshd_config.d/00-hardening.conf` sets:

| Directive | Value | Why not the fleet value |
|---|---|---|
| `PasswordAuthentication` | `no` | Same as the fleet |
| `PermitRootLogin` | `prohibit-password` | The role writes `no`. Root is the only administrative account here - `media` (uid 1000) has neither sudo nor `authorized_keys` - so `no` would end SSH administration of the hypervisor |

The deviation is stated in the file itself, so a later reader does not mistake it for drift.

**How it was applied, because the method matters more than the change.** This host has no usable
out-of-band console: the single GPU is passed through to vm100 with `x-vga=1`, there is no serial
console in the kernel cmdline and no BMC. `getty@tty1` runs but writes to a framebuffer the guest
owns. The Proxmox web shell on `:8006` works and is independent of all of that, but it was not
verified at the time.

So the change was made behind a dead-man switch: a transient
`systemd-run --on-active=10min` unit that restores the backed-up config and *restarts* sshd, armed
before anything was touched and cancelled only after a freshly established connection proved the
new configuration works. Had the operator's workstation frozen mid-operation - which it had done
once that afternoon - the host would have repaired itself without any console. `sshd -t` gated the
reload, so a syntax error could never reach a running daemon.

Verified after: fresh connection as root, `sshd -T` reporting `passwordauthentication no` and
`permitrootlogin without-password` (sshd's normalised spelling of `prohibit-password`), and a
counter-test with `PubkeyAuthentication=no` answered `Permission denied (publickey)` - the server
no longer offers a password path at all. Ten guests running, zero failed units.

Residual, not fixed here: root's `authorized_keys` on this host holds eight keys and nothing manages
the set. The VMs have the `breakglass` role enforcing theirs with `exclusive: true`.

## Storage definitions (cleaned 2026-08-17)

A `dir` storage named `mergerfs` pointed at `/mergerfs`, a plain directory on `pve-root` with no
filesystem mounted at it. It was registered for `images,rootdir` and marked `shared 1`, which is
meaningless on a single node. `pvesm status` reported it with `pve-root`'s free space, so allocating
a disk there would have written onto the KE-14 boot SSD - the KE-7 failure class, and sharper than
the `appdata_aux-disk` case, because that storage at least has a disk that could fail to mount.

Removed after verifying it was unused: three empty directories totalling 16 KB, no guest config
referencing it, no backup job, no replication entry. `/mergerfs` itself was left on disk.

In the same pass, `appdata_aux-disk` gained `is_mountpoint 1`, which had been deferred to the
hardware window and needed nothing from it. Proxmox now refuses to treat the storage as active
unless a filesystem is really mounted at the path. Verified immediately: storage still `active`,
vm100's `scsi1` still resolvable, guests untouched.

Noticed while applying it: `mkdir 0` is deprecated and slated for removal in PVE 9, which this host
already runs. The replacement is `create-base-path 0`.

## Related Documents

- [Operations](./operations.md) - boot ordering and maintenance routines
- [VM102 - Storage](../nodes/vm102.md) - SnapRAID cron schedule on VM102
- [ansible/roles/homelab_schedule/](../../ansible/roles/homelab_schedule/) - role that deploys scripts + cron file
