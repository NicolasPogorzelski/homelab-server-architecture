# Runbook: Host console through a GPU swap

## Problem

The Proxmox host has no local console in normal operation. Its only GPU, the RTX 2070 SUPER at
PCI address `08:00`, is passed through to vm100 with `x-vga=1`, and the Ryzen 5 2600X has no
integrated graphics. A monitor on the host shows nothing after the early boot.

Two remote paths exist without that: the tailnet, and since 2026-10-01 SSH over the LAN from the
two admin workstations, admitted by the `lan_guard` table. This runbook is the third path, for the
case where both fail: a spare GPU that the host keeps for itself.

It works because of how the passthrough is configured, measured 2026-10-01:

| Host setting | Effect on a spare card |
|---|---|
| `options vfio-pci ids=10de:1e84,10de:10f8,10de:1ad8,10de:1ad9` | `vfio-pci` claims the 2070 SUPER by device ID. A card with other IDs, such as a GTX 1080, stays with the host. |
| `blacklist nouveau`, `blacklist nvidia*` | No driver loads for the spare card; the UEFI framebuffer (`efifb`) drives a text console on it. |

**The trap:** vm100 has `onboot: 1` and `hostpci0: 08:00`. The passthrough is bound to the PCI
address, not to the card. A spare card in the same slot is handed to vm100 when it autostarts, and
the console goes dark a few minutes into the boot. Suppress guest autostart for that one boot, as
below.

## Preconditions

- The cheaper paths have been tried and have failed:
  - `ssh root@<proxmox-lan-ip>` from the admin notebook or the admin desktop
  - `ssh server` or the WebUI over the tailnet
- A spare NVIDIA card whose device ID is not in the `vfio-pci` list (a GTX 1080 is kept for this),
  with the PSU connectors it needs.
- A monitor and a USB keyboard at the host.
- The root password of the host (escrow). The console login is `root`, without the `@pam` that the
  WebUI shows.
- Guests stop when the host powers down. If the host still answers anything, shut it down cleanly;
  otherwise a long press on the power button.

## Procedure

### 1. Swap the card

Power off and disconnect mains. Remove the 2070 SUPER, fit the spare card in the same slot, so it
enumerates at `08:00` (the slot is what vm100's passthrough is bound to), and connect its power.
Connect the monitor to the spare card.

### 2. Boot without guests

1. Power on. The GRUB menu shows for 5 seconds (`GRUB_TIMEOUT=5`).
2. With the Proxmox entry highlighted, press `e`.
3. At the end of the line starting with `linux`, append:
   ```
   systemd.mask=pve-guests.service
   ```
4. Boot with `Ctrl+X`.

`pve-guests.service` is the unit that autostarts every guest (`pvesh create /nodes/localhost/startall`).
Masking it on the kernel command line applies to this boot only and writes nothing to disk, so no
guest starts and the spare card stays with the host.

### 3. Log in and repair

Log in at the console as `root`. The usual causes and their checks:

```bash
systemctl status tailscaled
tailscale status
journalctl -b -u tailscaled --no-pager | tail -40
nft list table inet lan_guard          # break-glass rule present, sources correct?
ip -4 addr show vmbr0                  # did the host keep its LAN address?
```

If the LAN filter itself is what locks you out, `systemctl disable --now lan-guard.service`
removes it until the next role run.

### 4. Swap back

Shut down, disconnect mains, refit the 2070 SUPER in the same slot, reconnect power, boot normally.
Guests autostart as usual.

## Verification

After the swap back, from the admin notebook:

```bash
ssh server 'lspci -nnk -s 08:00.0 | grep -E "1e84|in use"'   # 10de:1e84, Kernel driver in use: vfio-pci
ssh server 'qm list | grep -w 100'                           # vm100 running
ssh server 'tailscale status --self --peers=false'
```

Then the fleet as usual: Prometheus targets up, `systemctl --failed` empty on the host.

## Failure

- **No picture on the spare card:** check the monitor is on the spare card's outputs and that the
  firmware's primary display is set to the PCIe slot.
- **The console goes dark after a few minutes:** guest autostart was not suppressed and vm100 took
  the card. Hold the power button, boot again and add the GRUB line.
- **GRUB menu does not appear:** press `Esc` repeatedly during firmware hand-off to stop at the menu.
- **vm100 fails to start after the swap back:** the card is not at `08:00`. `lspci -nn` shows where
  it enumerated; refit it in the original slot rather than changing vm100's configuration.

## Rollback

Nothing on disk is changed by this procedure: the masking lasts one boot and the card swap is
reversed in step 4. If step 3 disabled `lan-guard.service`, run the `lan-guard.yml` playbook for the
host once the tailnet is back to restore the filter.

## Related

- [Hard shutdown recovery](hard-shutdown-recovery.md) - access hierarchy, of which this is the last step
- [sshd binding decision](../../docs/decisions/sshd-listen-address.md) - why the host has no out-of-band console
- [KE-21](../../docs/platform/known-errors.md#ke-21) - the host alive and unreachable for two hours
- `lan_guard` role - [ansible.md](../../docs/platform/ansible.md)
