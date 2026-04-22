#!/usr/bin/env bash
set -euo pipefail

# Update node_exporter systemd unit to bind to Tailscale IP only.
# Run from Proxmox host as root.
# Requires: pct (Proxmox), ssh access to storage + gpu hosts.

UNIT_PATH="/etc/systemd/system/node_exporter.service"

write_unit() {
  local ip="$1"
  cat << UNIT
[Unit]
Description=Prometheus Node Exporter
After=network.target tailscaled.service
Wants=tailscaled.service

[Service]
User=node_exporter
ExecStart=/usr/local/bin/node_exporter --web.listen-address=${ip}:9100
Restart=on-failure
RestartSec=15s

[Install]
WantedBy=multi-user.target
UNIT
}

apply_lxc() {
  local ctid="$1"
  local ip="$2"
  local name="$3"
  echo "==> LXC${ctid} (${name}, ${ip})"
  write_unit "$ip" | pct exec "$ctid" -- bash -c "cat > ${UNIT_PATH}"
  pct exec "$ctid" -- systemctl daemon-reload
  pct exec "$ctid" -- systemctl restart node_exporter
  sleep 3
  pct exec "$ctid" -- systemctl is-active node_exporter
}

apply_ssh() {
  local host="$1"
  local ip="$2"
  echo "==> ${host} (${ip})"
  write_unit "$ip" | ssh "$host" "cat > ${UNIT_PATH}"
  ssh "$host" "systemctl daemon-reload && systemctl restart node_exporter"
  sleep 3
  ssh "$host" "systemctl is-active node_exporter"
}

apply_local() {
  local ip="$1"
  echo "==> Proxmox host (${ip})"
  cat > "${UNIT_PATH}" << UNIT
[Unit]
Description=Prometheus Node Exporter
After=network.target tailscaled.service
Wants=tailscaled.service

[Service]
User=node_exporter
ExecStart=/usr/local/bin/node_exporter --web.listen-address=${ip}:9100 --collector.textfile.directory=/var/lib/node_exporter/textfile_collector
Restart=on-failure
RestartSec=15s

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl restart node_exporter
  sleep 3
  systemctl is-active node_exporter
}

# LXCs
apply_lxc 210 "TAILSCALE_IP_LXC210" "nextcloud"
apply_lxc 211 "TAILSCALE_IP_LXC211" "paperless"
apply_lxc 220 "TAILSCALE_IP_LXC220" "calibreweb"
apply_lxc 230 "TAILSCALE_IP_LXC230" "openwebui"
apply_lxc 240 "TAILSCALE_IP_LXC240" "vaultwarden"
apply_lxc 250 "TAILSCALE_IP_LXC250" "devops"
apply_lxc 260 "TAILSCALE_IP_CT260"  "postgres"

# VMs (via SSH, requires key-based auth from Proxmox host)
apply_ssh "storage" "TAILSCALE_IP_VM102"
apply_ssh "gpu"     "TAILSCALE_IP_VM100"

# Proxmox host (run locally)
apply_local "TAILSCALE_IP_PROXMOX"

echo ""
echo "==> Done. Run Prometheus targets check to verify."
