# LXC250 Rebuild

Procedure for recreating the DevOps workstation from scratch after loss or intentional rebuild.
Running services on other nodes are not affected - LXC250 is not in the data path.

## Preconditions

- Proxmox host is accessible via console or SSH
- Tailscale admin console is accessible to authorize the new node
- `github.com/NicolasPogorzelski/dotfiles` is reachable over HTTPS; the node needs no GitHub
  credential, because every repository it clones is public and it never pushes

---

## 1. Create LXC on Proxmox

From the Proxmox host, check available templates first:

```bash
pveam list local
```

Create the container (adjust storage pool and bridge to match your Proxmox setup):

```bash
pct create 250 local:vztmpl/<debian-12-template>.tar.zst \
  --hostname devops \
  --cores 2 \
  --memory 2048 \
  --swap 512 \
  --rootfs local-lvm:8 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --unprivileged 1 \
  --features nesting=1 \
  --onboot 1
```

`<debian-12-template>` - use the current template name from `pveam list local`.
`local-lvm` and `vmbr0` - adjust to your Proxmox storage pool and bridge if needed.

Add Tailscale TUN config to `/etc/pve/lxc/250.conf`:

```
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
```

Start the container:

```bash
pct start 250
pct exec 250 -- bash
```

---

## 2. Base system setup

```bash
apt-get update && apt-get install -y sudo curl git python3 python3-venv pipx tmux
useradd -m -s /bin/bash -G sudo devops
```

Generate a random temporary password and save it in your password manager immediately:

```bash
PASS=$(openssl rand -base64 16)
echo "devops:$PASS" | chpasswd
echo "Temporary password: $PASS - save this in your password manager now"
```

Switch to devops user for all remaining steps:

```bash
su - devops
```

---

## 3. Tailscale

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --advertise-tags=tag:control
```

Authorize the new node in the Tailscale admin console.

Verify:

```bash
tailscale status
tailscale ip -4
```

---

## 4. SSH - bind to Tailscale IP

Edit `/etc/ssh/sshd_config`, set:

```
ListenAddress <tailscale-ip-lxc250>
PasswordAuthentication no
```

Add systemd drop-in to handle startup ordering:

```bash
sudo mkdir -p /etc/systemd/system/ssh.service.d
sudo tee /etc/systemd/system/ssh.service.d/override.conf <<'EOF'
[Unit]
After=tailscaled.service
Wants=tailscaled.service

[Service]
Restart=on-failure
RestartSec=15s
RestartPreventExitStatus=
EOF

sudo systemctl daemon-reload
sudo systemctl restart ssh
```

Lock the devops password - SSH key is the only login path from this point:

```bash
sudo passwd -l devops
```

---

## 5. SSH key for Ansible

```bash
ssh-keygen -t ed25519 -C "devops@lxc250" -f ~/.ssh/id_ed25519
```

This is the key Ansible connects with (`ansible.cfg` names none, so the default applies). It is
not registered on GitHub: since 2026-10-12 the node holds no GitHub credential and fetches over
HTTPS. A restore from the guest backup brings the original key back, which the fleet's `ansible`
accounts already trust; a new key has to be distributed with `bootstrap.yml` first.

---

## 6. dotfiles

```bash
git clone https://github.com/NicolasPogorzelski/dotfiles.git ~/git/dotfiles
cd ~/git/dotfiles
./validate.sh
./bootstrap.sh
./install.sh --dry-run
./install.sh
```

---

## 7. Clone repos

```bash
git clone https://github.com/NicolasPogorzelski/homelab-server-architecture.git \
  ~/git/homelab-server-architecture
git clone https://github.com/NicolasPogorzelski/devops-til.git \
  ~/git/devops-til
```

---

## Verification

```bash
git --version
ansible --version
claude --version
tailscale status
git -C ~/git/homelab-server-architecture fetch origin
git -C ~/git/homelab-server-architecture log --oneline -3
```

All commands should return without error.

---

## Failure Modes

**SSH unreachable after reboot**
Tailscale may not be up before SSH starts. The systemd drop-in (step 4) prevents
this. If it still occurs: access via Proxmox console (`pct exec 250 -- bash`),
then `sudo systemctl restart ssh`.

**Tailscale auth loop**
Run `sudo tailscale up --force-reauth` and re-authorize in the admin console.

**`git fetch` asks for credentials**
The remote is an SSH URL or the repository went private. `git remote -v` must show
`https://github.com/...`; a private repository does not belong on this node.

**bootstrap.sh fails on Claude Code install**
The installer requires internet access. Verify with `curl -I https://claude.ai`.
If the install script URL has changed, check the official Claude Code documentation
for the current install command.

---

## Rollback

The safest property of this procedure is that it **builds a new container instead of repairing the
old one**, so the rollback is simply not to switch over.

- Keep the old CT250 in place, stopped rather than destroyed, until the new one has passed the
  Verification section. The constraint is thin-pool space on the boot SSD -- check it before
  starting, not after.
- If the new container fails verification: `pct stop <new>` and `pct start 250`. Nothing outside the
  container changes, because lxc250 is a control node and no service depends on it.
- Destroy the old container only after a full Ansible run from the new one has completed against at
  least one node.

**What has no rollback is the un-versioned material.** `~/.vault_pass`, the real `hosts.yml` and the
Ansible SSH key are gitignored and exist only on this node. If they were not recovered from the old
container or retrieved from the escrow, the rebuild produces a control node that cannot decrypt
anything. Confirm you hold them before creating the new container, not after destroying the old
one.
