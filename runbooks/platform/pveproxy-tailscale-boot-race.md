# Runbook: pveproxy down after boot (Tailscale address bind race)

- **Use when:** after a host boot SSH works but the Proxmox web UI on `:8006` is unreachable and
  `systemctl is-active pveproxy` prints `failed`.
- **Duration:** 5 minutes for the restart; 10 minutes to redeploy the boot gate.
- **Risk:** low; pveproxy serves only the UI and API, guests keep running.
- **Last exercised:** 2026-06-25, pass ([KE-12](../../docs/platform/known-errors.md#ke-12): restart
  plus boot gate; the gate held on a cold boot on 2026-08-13).

`pveproxy` binds only the host's Tailscale address (`LISTEN_IP=<tailscale-ip-proxmox-host>` in
`/etc/default/pveproxy`). If it starts before `tailscaled` has put that address on `tailscale0`, the
bind fails with `EADDRNOTAVAIL`, it exits, and after five fast retries systemd stops trying:

```
pveproxy[...]: start failed - unable to create socket - Cannot assign requested address
pveproxy.service: Start request repeated too quickly.
```

The durable fix is the [`tailscale_boot_gate`](../../ansible/roles/tailscale_boot_gate/) role. For
every unit in `tailscale_boot_gate_units` (`pveproxy.service` in
`ansible/inventory/group_vars/proxmox.yml`) it installs `10-wait-tailscale.conf`, whose
`ExecStartPre` runs `snippets/scripts/wait-for-tailscale-ip.sh` (deployed to
`/usr/local/bin/wait-for-tailscale-ip.sh`), plus `Restart=on-failure` with `RestartSec=15s`. It
removes the hand-written drop-ins it supersedes. No address is written into the unit.

## Preconditions

- Root shell on the host: `ssh root@<tailscale-ip-proxmox-host>`, or break-glass SSH over the LAN
  (`ssh root@<lan-ip-proxmox>`).
- The address exists now: `ip -4 addr show tailscale0` shows an `inet` line. If not, fix Tailscale
  first (`tailscale status`); pveproxy cannot bind an address that is not there.

## Steps

1. Confirm the cause.
   ```bash
   systemctl is-active pveproxy
   ss -tlnp | grep 8006 || echo "nothing on 8006"
   journalctl -u pveproxy -b --no-pager | tail -20
   ```
   Check: `failed`, nothing on 8006, and `Cannot assign requested address` in the journal. Any other
   error (certificate, `pmxcfs`) means this runbook does not apply.

2. Clear the start limit and restart.
   ```bash
   systemctl reset-failed pveproxy
   systemctl restart pveproxy
   ```
   Check: `systemctl is-active pveproxy` prints `active`.

3. Confirm the boot gate is in place.
   ```bash
   systemctl cat pveproxy | grep -E 'ExecStartPre|^# /etc'
   ls /etc/systemd/system/pveproxy.service.d/
   ```
   Check: the only drop-in is `10-wait-tailscale.conf`, and `ExecStartPre` calls
   `/usr/local/bin/wait-for-tailscale-ip.sh`. If not, continue with step 4; otherwise go to
   Verification.

4. Redeploy the gate from lxc250 (`ansible/` directory), dry run first.
   ```bash
   ansible-playbook playbooks/tailscale-boot-gate.yml --limit proxmox --check --diff
   ansible-playbook playbooks/tailscale-boot-gate.yml --limit proxmox
   ```
   Check: a second run reports `changed=0`; step 3 now passes.

## Verification

```bash
systemctl is-active pveproxy
ss -tlnp | grep 8006
curl -k -s -o /dev/null -w '%{http_code}\n' --max-time 8 https://<tailscale-ip-proxmox-host>:8006
systemd-analyze verify pveproxy.service
```

Expected: `active`; a listener on `<tailscale-ip-proxmox-host>:8006`; HTTP `200`; no output from
`systemd-analyze`. After the next boot, `journalctl -b -u pveproxy` shows
`wait-for-tailscale-ip: <address> present after Ns` and `systemctl show -p NRestarts pveproxy` is
`NRestarts=0`.

Verified 2026-08-13 (cold boot, earlier hand-written gate): the unit started once, `NRestarts=0`,
the poll absorbed a four-second wait for the address.

## Failure modes

| Symptom | Cause | Action |
|---|---|---|
| Restart fails with `Cannot assign requested address` | `tailscale0` has no address | `tailscale status`; bring Tailscale up first |
| Restart refused: `start request repeated too quickly` | `reset-failed` skipped | Step 2 in order |
| Other pveproxy error (certificate, `/etc/pve`) | Not this race | `systemctl status pvedaemon pve-cluster`; `pvecm updatecerts` |
| Gate present, unit still failed after boot | Gate timed out (fail-open after `tailscale_boot_gate_timeout`) and the bind failed | `journalctl -b -u tailscaled`; the 15 s restart backstop should recover it, check `NRestarts` |
| A second drop-in overrides the gate | Hand-written file left beside the role's | Add it to `tailscale_boot_gate_obsolete_dropins`, rerun step 4 |

## Rollback

Steps 1 to 3 change nothing persistent. To remove the gate, drop `pveproxy.service` from
`tailscale_boot_gate_units` in `ansible/inventory/group_vars/proxmox.yml`, or by hand:

```bash
rm /etc/systemd/system/pveproxy.service.d/10-wait-tailscale.conf
systemctl daemon-reload
```

pveproxy then starts with stock ordering and the race returns on the next boot.

## Background

Ordering after `tailscaled.service` alone does not help: systemd counts a unit as started when its
process runs, not when the address is assigned ([KE-18](../../docs/platform/known-errors.md#ke-18)).
The gate polls until `tailscale ip -4` is on a local interface. It is fail-open, so a slow tailnet
delays pveproxy instead of keeping it down. Decision:
[pveproxy-tailscale-boot-ordering](../../docs/decisions/pveproxy-tailscale-boot-ordering.md).
Host context: [proxmox-host.md](../../docs/platform/proxmox-host.md).
