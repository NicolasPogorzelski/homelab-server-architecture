# Runbook: lxc250 rebuild

- **Use when:** lxc250 (Ansible control node) is lost or broken and has to be recreated.
- **Duration:** 15 minutes from a vzdump; 1-2 hours for a rebuild from template.
- **Risk:** without the escrowed vault password, real inventory and Ansible SSH key the new node
  cannot decrypt or reach anything; a restored clone started beside the original takes over its
  Tailscale identity.
- **Last exercised:** never

lxc250 is in no service's data path; running services are unaffected while it is down. Node facts:
[lxc250.md](../../docs/nodes/lxc250.md).

## Preconditions

- Root shell on the Proxmox host; access to the Tailscale admin console.
- Thin-pool headroom for a second container if the old one is kept: `lvs pve/data`.
- For a rebuild from template: the escrow at hand
  ([escrow-restore-drill.md](escrow-restore-drill.md)); confirm all three artefacts before creating
  anything.

## Steps

### Restore from vzdump (first choice)

1. Restore the newest lxc250 archive per [guest-backup-restore.md](guest-backup-restore.md): into
   250 if the old container is gone; if it is kept for comparison, stop it and use a free ID.
   ```bash
   ls -t /mnt/vzdump/vzdump-lxc-250-*.tar.zst | head -1
   pct restore <free-ctid> <archive> --storage local-lvm
   ```
   Check: `pct config <free-ctid>` shows hostname `devops`. Never run both with the same
   Tailscale identity.
2. Start it and update the checkout.
   ```bash
   pct start <ctid>
   pct exec <ctid> -- su - devops -c 'git -C ~/git/homelab-server-architecture pull --ff-only'
   ```
   Check: continue at Verification. If the archive is unusable, rebuild from template below.

### Rebuild from template

3. Create the container. Use 250 if the old container is gone, otherwise a free ID.
   ```bash
   pveam list local
   pct create <ctid> local:vztmpl/<debian-12-template>.tar.zst \
     --hostname devops --cores 2 --memory 2048 --swap 512 --rootfs local-lvm:8 \
     --net0 name=eth0,bridge=vmbr0,ip=dhcp --unprivileged 1 --features nesting=1 --onboot 1
   cat >> /etc/pve/lxc/<ctid>.conf <<'EOF'
   lxc.cgroup2.devices.allow: c 10:200 rwm
   lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
   EOF
   pct start <ctid>
   ```
   Check: `pct exec <ctid> -- ls -l /dev/net/tun` shows a character device.
4. Base system and user.
   ```bash
   pct exec <ctid> -- bash -c 'apt-get update && apt-get install -y sudo curl git python3 python3-venv pipx tmux'
   pct exec <ctid> -- useradd -m -s /bin/bash -G sudo devops
   PASS=$(openssl rand -base64 16); echo "devops:$PASS" | pct exec <ctid> -- chpasswd; echo "$PASS"
   ```
   The temporary password is for `sudo` during setup only; step 11 locks it.
   Check: `pct exec <ctid> -- id devops` lists group `sudo`.
5. Tailscale.
   ```bash
   pct exec <ctid> -- bash -c 'curl -fsSL https://tailscale.com/install.sh | sh'
   pct exec <ctid> -- tailscale up --advertise-tags=tag:control
   ```
   Authorize the node in the admin console; remove the old `devops` node there if it is gone.
   Check: `pct exec <ctid> -- tailscale ip -4` prints the address.
6. Restore the escrowed artefacts as `devops`, mode 0600.
   ```bash
   pct enter <ctid>
   su - devops
   git clone https://github.com/NicolasPogorzelski/homelab-server-architecture.git ~/git/homelab-server-architecture
   install -m 0600 /dev/null ~/.vault_pass                                          # paste the vault password
   install -m 0600 /dev/null ~/git/homelab-server-architecture/ansible/inventory/hosts.yml  # paste the inventory
   install -m 0700 -d ~/.ssh && install -m 0600 /dev/null ~/.ssh/id_ed25519          # paste the private key
   ssh-keygen -y -f ~/.ssh/id_ed25519 > ~/.ssh/id_ed25519.pub
   ```
   Check: `ssh-keygen -lf ~/.ssh/id_ed25519.pub` prints a fingerprint; `git status` in the checkout
   is clean (both files are gitignored).
7. Install Ansible and its collections.
   ```bash
   pipx install --include-deps ansible
   pipx ensurepath && exec bash -l
   cd ~/git/homelab-server-architecture/ansible && ansible-galaxy collection install -r requirements.yml
   ```
   Check: `ansible --version` prints a version and `config file = .../ansible/ansible.cfg`.
8. Seed the trust anchor and build the fleet's known_hosts. Read the hypervisor's key on its
   console (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`) and compare it with the network:
   ```bash
   ssh-keyscan -t ed25519 <tailscale-ip-proxmox> | ssh-keygen -lf -
   ssh-keyscan -t ed25519 <tailscale-ip-proxmox> | ssh-keygen -H -f - > ~/.ssh/known_hosts.fleet 2>/dev/null
   ansible-playbook playbooks/known-hosts.yml
   ```
   Check: both fingerprints are equal before the second line runs; the playbook reports no failed
   host and a second run `changed=0`. `ansible.cfg` refuses every node whose key is not in the file.
9. On the host: create the `ansible` account on the node, as root in the container; the playbook
   cannot create the account it connects with.
   ```bash
   pct exec <ctid> -- bash /home/devops/git/homelab-server-architecture/snippets/scripts/bootstrap-ansible-user-lxc250.sh
   ```
   Check: a second run reports every item unchanged.
10. From `ansible/` as `devops`, bring the node under its own roles, gate before pin.
   ```bash
   for p in tailscale-boot-gate ssh-hardening nsswitch; do
     ansible-playbook playbooks/$p.yml --limit lxc250 --check --diff && ansible-playbook playbooks/$p.yml --limit lxc250
   done
   ```
   Check: `ss -ltn` shows port 22 on `<tailscale-ip-lxc250>` only. Then run every playbook in the
   `[playbooks]` section of `ansible/drift-sweep.conf` with `--limit lxc250`; the node's roles are
   listed in [lxc250.md](../../docs/nodes/lxc250.md#configuration-management).
11. Dotfiles.
    ```bash
    git clone https://github.com/NicolasPogorzelski/dotfiles.git ~/git/dotfiles
    cd ~/git/dotfiles && ./validate.sh && ./bootstrap.sh && ./install.sh --dry-run && ./install.sh
    ```
    Then lock the temporary password: `sudo passwd -l devops`.
    Check: `install.sh` exits 0; `sudo passwd -S devops` shows `L`.

With the escrowed key the fleet's `ansible` accounts already trust the node. A new key must be
distributed with `ansible/playbooks/bootstrap-ansible-user.yml`, which connects as root.

## Verification

From `~/git/homelab-server-architecture/ansible` as `devops`:
```bash
ansible --version
ansible all -m ping
ansible-vault view inventory/group_vars/all/vault.yml >/dev/null && echo decrypts
git -C ~/git/homelab-server-architecture fetch origin && git -C ~/git/homelab-server-architecture status -sb
tailscale status --self --peers=false
```

- All ten nodes answer `pong`; the vault decrypts; the checkout is `main` equal to `origin/main`.
- `ansible-playbook playbooks/fleet-health-check.yml` completes; `systemctl list-timers` shows
  `fleet-drift.timer` and the fleet snapshot timer.

## Failure modes

| Symptom | Cause | Action |
|---|---|---|
| SSH refused after reboot | `tailscaled` not up yet; sshd binds the Tailscale address behind `tailscale_boot_gate` | `pct exec <ctid> -- tailscale status`; wait or restart `tailscaled` |
| Tailscale auth loop | Stale node state | `tailscale up --force-reauth`; re-authorize in the console |
| `git fetch` asks for credentials | Remote is an SSH URL | `git remote -v` must show `https://github.com/...` |
| `Permission denied (publickey)` from every node | Key is not the escrowed one | Restore the escrowed key (step 6) |
| `preflight` refuses the run | Checkout not clean `main` equal to `origin/main` | `git status`; `git pull --ff-only` |

## Rollback

The procedure builds a new container instead of repairing the old one. Keep the old one stopped
until the new one passes Verification and has completed one Ansible run against at least one node.
If verification fails: `pct stop <new-ctid>`, `pct start 250`. Nothing outside the container
changes. If the old container is gone, there is no rollback: the escrow is what makes the rebuild
possible.

## Background

lxc250 holds no GitHub credential; its repositories are public and fetched over HTTPS. The node
only pulls; changes reach `main` by pull request. Its `ansible` account is created by
`snippets/scripts/bootstrap-ansible-user-lxc250.sh` because `bootstrap-ansible-user.yml` excludes
lxc250: it connects as root, which `ssh_hardening` refuses there.
