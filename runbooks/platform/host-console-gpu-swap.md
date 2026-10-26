# Runbook: Host console through a GPU swap

- **Use when:** the host is up but unreachable over the tailnet and over break-glass LAN SSH.
- **Duration:** 30-60 minutes with physical presence.
- **Risk:** if guest autostart is not suppressed, vm100 takes the spare card and the console goes
  dark; every guest is down for the duration.
- **Last exercised:** never

The host has no local console in normal operation: its only GPU (RTX 2070 SUPER, PCI `08:00`) is
passed through to vm100 with `x-vga=1`, and the CPU has no integrated graphics. A spare card that
`vfio-pci` does not claim gives the host a text console. Host settings that make this work,
measured 2026-10-01:

| Host setting | Effect on a spare card |
|---|---|
| `options vfio-pci ids=10de:1e84,10de:10f8,10de:1ad8,10de:1ad9` | Claims the 2070 SUPER by device ID; a card with other IDs (the GTX 1080 kept for this) stays with the host |
| `blacklist nouveau`, `blacklist nvidia*` | No driver loads; the UEFI framebuffer (`efifb`) drives a text console |

vm100's `hostpci0: 08:00` binds the PCI address, not the card: a spare card in the same slot is
handed to vm100 when it autostarts. Step 2 suppresses autostart for one boot.

## Preconditions

- Paths 1 and 2 of [hard-shutdown-recovery.md](hard-shutdown-recovery.md#preconditions) failed:
  `ssh server` or the WebUI over the tailnet, and `ssh root@<lan-ip-proxmox>` from an admin
  workstation.
- A spare NVIDIA card whose device ID is not in the `vfio-pci` list, with its PSU connectors.
- Monitor and USB keyboard at the host.
- The host's root password from the escrow. Console login is `root`, without `@pam`.
- The host shut down cleanly if it answers anything; otherwise a long press on the power button.

## Steps

1. Power off, disconnect mains. Replace the 2070 SUPER with the spare card in the same slot,
   connect its power and the monitor.
   Check: the firmware screen shows on the spare card.
2. Boot with guest autostart masked. In GRUB (5 s, `GRUB_TIMEOUT=5`) press `e` on the Proxmox
   entry, append to the `linux` line:
   ```
   systemd.mask=pve-guests.service
   ```
   Boot with `Ctrl+X`. The mask applies to this boot only and writes nothing to disk.
   Check: a login prompt appears and stays; `qm list` shows vm100 `stopped`.
3. Log in as `root` and find the cause.
   ```bash
   systemctl status tailscaled
   tailscale status
   journalctl -b -u tailscaled --no-pager | tail -40
   nft list table inet lan_guard          # break-glass rule present, sources correct
   ip -4 addr show vmbr0                  # LAN address present
   ```
   If the LAN filter is what locks access out: `systemctl disable --now lan-guard.service` (off
   until the next role run).
   Check: `tailscale status` shows the host online, or `ssh root@<lan-ip-proxmox>` from an
   admin workstation works.
4. Shut down, disconnect mains, refit the 2070 SUPER in the same slot, boot normally.
   Check: guests autostart.

## Verification

From an admin workstation:
```bash
ssh server 'lspci -nnk -s 08:00.0 | grep -E "1e84|in use"'   # 10de:1e84, Kernel driver in use: vfio-pci
ssh server 'qm list | grep -w 100'                           # running
ssh server 'tailscale status --self --peers=false'
ssh server 'systemctl --failed --no-legend'                  # empty
```

Prometheus targets are up.

## Failure modes

| Symptom | Cause | Action |
|---|---|---|
| No picture on the spare card | Monitor on the wrong output, or firmware primary display not PCIe | Check cabling and the firmware display setting |
| Console goes dark after a few minutes | Autostart not suppressed; vm100 took the card | Power off, boot again, step 2 |
| GRUB menu does not appear | Firmware hand-off too fast | Press `Esc` repeatedly during hand-off |
| vm100 fails to start after the swap back | Card not at `08:00` | `lspci -nn`; refit it in the original slot; leave vm100's configuration as it is |

## Rollback

Nothing on disk changes: the mask lasts one boot and step 4 reverses the swap. If step 3 disabled
`lan-guard.service`, run `ansible/playbooks/lan-guard.yml` for the host once the tailnet is back.

## Background

Related: [sshd binding decision](../../docs/decisions/sshd-listen-address.md) (why the host keeps
LAN SSH), [KE-21](../../docs/platform/known-errors.md#ke-21) (host alive and unreachable for two
hours), `lan_guard` in [ansible.md](../../docs/platform/ansible.md).
