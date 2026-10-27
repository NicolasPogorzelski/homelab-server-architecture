# Runbook: Hard shutdown recovery (Proxmox host)

- **Use when:** the host went down uncleanly (power loss, forced power-off, watchdog) and after the
  reboot guests are stopped, fail to start, or are unreachable.
- **Duration:** 10-20 minutes.
- **Risk:** a container started before its SMB share is mounted writes into the empty mountpoint
  on the boot SSD ([KE-7](../../docs/platform/known-errors.md#ke-7) class); more guest starts on a
  boot SSD that logs I/O errors add load to a failing device
  ([KE-14](../../docs/platform/known-errors.md#ke-14)).
- **Last exercised:** never

Guests autostart by `startup: order=N,up=M` ([boot ordering](../../docs/platform/proxmox-host.md#boot-ordering)):
vm102 first, because the host's `/mnt/smb/*` CIFS automounts and the bind mounts of lxc210, lxc220
and lxc260 depend on its shares. After an unclean shutdown that order can break: lxc260's pre-start
hook exits 19 (`ENODEV`) when `/mnt/smb/postgres-backups` is not ready.

## Preconditions

- The host has finished booting (link up on the NIC).
- A root shell on the host, by the first path that works:

| Priority | Path | Available when |
|---|---|---|
| 1 | WebUI `https://<tailscale-ip-proxmox-host>:8006` or `ssh server` over the tailnet | `tailscaled` on the host is up; `pveproxy` binds the Tailscale address only |
| 2 | `ssh root@<lan-ip-proxmox>` | From one of the two admin workstations; `lan_guard` drops every other LAN source |
| 3 | Physical console through a spare GPU | Paths 1 and 2 failed: [host-console-gpu-swap.md](host-console-gpu-swap.md) |

`<lan-ip-proxmox>` is in the real inventory on lxc250 and in the router's DHCP table (host
`server`).

## Steps

1. Read the state and the boot SSD before starting anything.
   ```bash
   qm list; pct list
   journalctl -k -b | grep -cE '9:0:0:0.*(DID_SOFT_ERROR|DID_TIME_OUT)'
   ```
   Check: a count above zero that keeps rising means stop here (see Rollback).
2. Start vm102 if it is not running.
   ```bash
   qm start 102
   ```
   Check: `qm status 102` prints `status: running`.
3. Wait for its shares on the host.
   ```bash
   for s in postgres-backups nextcloud db-backups books books-rw; do
     ls /mnt/smb/$s >/dev/null; echo "$s: $(findmnt -no FSTYPE /mnt/smb/$s | tr '\n' ' ')"
   done
   systemctl restart smb-mounts-check.service
   ```
   Check: every line contains `cifs` (`autofs` alone means not mounted yet; wait 30-60 s and
   repeat); `smb-mounts-check.service` exits 0.
4. Start the stopped containers in startup order. SMB-dependent containers come only after step 3
   passed.
   ```bash
   pct start 260   # PostgreSQL; mp1 on /mnt/smb/postgres-backups
   pct start 200
   pct start 210   # Nextcloud; mp0, mp1 on SMB
   pct start 211
   pct start 220   # Calibre-Web; mp0, mp2 on SMB
   pct start 230
   pct start 250
   ```
   Skip containers already running. Check: `pct list` shows every container `running`; for a
   failure, `journalctl -u pve-container@<ctid>.service -n 30 --no-pager`.
5. Start vm100 last.
   ```bash
   qm start 100
   ```
   Check: `qm status 100` prints `status: running`.
6. Wait for SSH. sshd on every guest binds the Tailscale address only, behind
   `tailscale_boot_gate` ([sshd decision](../../docs/decisions/sshd-listen-address.md)); it is
   unreachable until `tailscaled` has its address.
   ```bash
   pct exec 250 -- tailscale status --self --peers=false
   ```
   Check: the node shows its Tailscale address. If stuck,
   `pct exec <ctid> -- systemctl restart tailscaled`.

## Verification

From lxc250, in `ansible/`:
```bash
ansible all -m ping
ansible all -b -m command -a 'systemctl --failed --no-legend'
```
On the host:
```bash
pct exec 260 -- systemctl is-active postgresql
pct exec 260 -- findmnt -no FSTYPE /mnt/backups
```

- Every node answers `pong` and lists no failed unit.
- PostgreSQL is `active`; `/mnt/backups` in lxc260 is `cifs`.
- No alert other than `Watchdog`.

## Failure modes

| Symptom | Cause | Action |
|---|---|---|
| `pct start 260` exits 19 | SMB share not mounted yet | Step 3, then retry |
| SSH to a guest refused right after boot | `tailscaled` not up yet | Wait 60 s; step 6 |
| Container runs, services failed | Units left failed by the unclean shutdown | `pct exec <ctid> -- systemctl --failed`; restart them |
| WebUI unreachable over the tailnet | `tailscaled` on the host not up | Path 2, then `systemctl restart tailscaled` (`pveproxy` waits for it, [KE-12](../../docs/platform/known-errors.md#ke-12)) |
| `ansible all -m ping` partly `UNREACHABLE` | Tailscale on those nodes not up | Wait 30-60 s; `pct exec <ctid> -- tailscale status` |
| Container fsck messages on start | Unclean unmount | `journalctl -u pve-container@<ctid>` for the outcome |
| No network at all after a board or NIC swap | `nic0` is pinned by MAC (`/usr/local/lib/systemd/network/50-pmx-nic0.link`); the new card keeps its own name and `vmbr0`'s `bridge-ports nic0` is empty | Procedure below |

### No network after a board or NIC swap

Not yet performed; the commands are the vendor's. `vfio-pci` claims the only GPU for vm100, so the
screen goes dark after GRUB.

1. In GRUB press `e`, append `modprobe.blacklist=vfio_pci` to the `linux` line, boot with
   `Ctrl-x`. The host keeps the GPU; vm100 fails to start this boot.
2. Log in as root; `ip -br link` shows the new card's name.
3. Pin it to the old name:
   ```bash
   mv /usr/local/lib/systemd/network/50-pmx-nic0.link /root/
   pve-network-interface-pinning generate --interface <new-name> --target-name nic0
   reboot
   ```
4. A new board has no `proxmox` UEFI entry and boots through `\EFI\BOOT\BOOTX64.EFI`; recreate the
   entry with `efibootmgr` if the firmware needs it.

## Rollback

There is no prior state to return to; these are the abort criteria:

- Step 3 does not pass: do not start SMB-dependent containers. A container started on an empty
  mountpoint keeps the empty directory and writes onto the boot SSD.
- A container fails twice for the same reason: stop and diagnose; repeating `pct start` adds
  nothing.
- The boot disk logs I/O errors that keep rising: stop starting guests
  ([boot disk replacement](boot-ssd-replacement.md)).

A container started too early is undone with `pct stop <ctid>` and started again after step 3.

## Background

Shut down with WebUI -> node -> Shutdown or `shutdown -h now`; a forced power-off only when the
host does not respond. If the host is unresponsive under heavy I/O, check the thin pool first:
`lvs pve/data` ([lvm-thin-pool-full.md](lvm-thin-pool-full.md)). If SMB-related start failures
recur after clean boots, raise vm102's `up` delay (WebUI -> vm102 -> Options -> Start/Shutdown
order).
