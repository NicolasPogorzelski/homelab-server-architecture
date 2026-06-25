# Runbook: pveproxy Down After Boot (Tailscale-IP Bind Race)

## Problem

After a host reboot, SSH works but the Proxmox web UI on `:8006` is unreachable.
`pveproxy` is configured to bind only the host Tailscale IP
(`/etc/default/pveproxy` → `LISTEN_IP=<tailscale-ip-proxmox-host>`) and started
before `tailscaled` assigned that IP, so it failed to bind and systemd gave up.

Observed failure signature:

```
pveproxy[...]: start failed - unable to create socket - Cannot assign requested address
pveproxy.service: Start request repeated too quickly.
pveproxy.service: Failed with result 'exit-code'.
```

Background: [KE-12](../../docs/platform/known-errors.md#ke-12-pveproxy-fails-to-start-after-boot-tailscale-ip-bind-race),
[ADR pveproxy-tailscale-boot-ordering](../../docs/decisions/pveproxy-tailscale-boot-ordering.md).

## Preconditions

- SSH access to the Proxmox host (the web UI is down, so use SSH):
  - Over Tailscale: `ssh root@<tailscale-ip-proxmox-host>`
  - Or over LAN: `ssh root@<lan-ip-proxmox-host>`
- `tailscaled` is up and the host Tailscale IP is now assigned:
  ```bash
  ip -4 addr show tailscale0
  ```
  If `tailscale0` has no IP, fix Tailscale first — pveproxy cannot bind an address
  that does not exist.

## Diagnosis

Confirm pveproxy is the cause (not a network/Tailscale problem):

```bash
systemctl is-active pveproxy            # expect: failed
ss -tlnp | grep 8006 || echo "nothing on 8006"
journalctl -u pveproxy -b --no-pager | tail -20   # look for "Cannot assign requested address"
```

`Cannot assign requested address` confirms the bind race. A different error (e.g.
a certificate problem) means this runbook does not apply.

## Recovery

### Immediate restart (the IP is present now)

```bash
systemctl reset-failed pveproxy
systemctl restart pveproxy
```

- `reset-failed` clears the failed state **and** the start-limit counter — without
  it, systemd refuses to restart after "start request repeated too quickly".
- The restart now succeeds because `tailscale0` already holds the IP.

### Durable fix (survive the next reboot)

Install the wait-for-IP drop-in so pveproxy waits for the Tailscale IP at boot:

```bash
mkdir -p /etc/systemd/system/pveproxy.service.d
cat > /etc/systemd/system/pveproxy.service.d/wait-tailscale.conf <<'EOF'
[Unit]
After=tailscaled.service
Wants=tailscaled.service

[Service]
ExecStartPre=/bin/bash -c 'for i in $(seq 1 30); do ip -4 addr show tailscale0 2>/dev/null | grep -q <tailscale-ip-proxmox-host> && exit 0; sleep 1; done; exit 1'
EOF
systemctl daemon-reload
```

Replace `<tailscale-ip-proxmox-host>` with the host's actual Tailscale IPv4.

## Verification

```bash
systemctl is-active pveproxy                 # active
ss -tlnp | grep 8006                         # LISTEN on <tailscale-ip-proxmox-host>:8006
curl -k -s -o /dev/null -w '%{http_code}\n' --max-time 8 https://<tailscale-ip-proxmox-host>:8006   # 200
```

Confirm the drop-in is registered:

```bash
systemctl cat pveproxy | grep -A4 wait-tailscale
systemd-analyze verify pveproxy.service      # no output = OK
```

The real test of the durable fix is a **cold boot**: after the next reboot,
`systemctl is-active pveproxy` should be `active` with no manual restart.

## Failure modes

| Symptom | Check / fix |
|---|---|
| `restart` still fails with `Cannot assign requested address` | `tailscale0` has no IP — `tailscale status`, bring Tailscale up first |
| `restart` rejected, "start request repeated too quickly" | `systemctl reset-failed pveproxy` was skipped — run it, then restart |
| Different `pveproxy` error (cert/`pmxcfs`) | Not this race; check `pvecm updatecerts`, `/etc/pve` mounted (`pvedaemon` active) |
| Drop-in present but cold boot still fails | The 30 s poll timed out (Tailscale slow to come up); raise the loop count or investigate `tailscaled` startup |

## Rollback / abort

Remove the durable fix (reverts to stock pveproxy startup):

```bash
rm /etc/systemd/system/pveproxy.service.d/wait-tailscale.conf
systemctl daemon-reload
```
