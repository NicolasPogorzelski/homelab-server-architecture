# Ansible Platform

This document describes the Ansible setup used to manage the homelab platform.

## Control Node

**LXC250** (`/home/devops/git/homelab-server-architecture/ansible/`)

All playbooks and roles are run from LXC250 over SSH via Tailscale. No direct LAN access is used.

## Inventory

- **File:** `ansible/inventory/hosts.yml` (gitignored — contains real Tailscale IPs)
- **Example:** `ansible/inventory/hosts.yml.example` (sanitized, committed)
- **9 managed nodes:** VM100, VM102, LXC200, LXC210, LXC211, LXC220, LXC230, LXC240, LXC260
- **LXC250 excluded** from inventory (control node does not manage itself)

Groups:

| Group | Members |
|---|---|
| `lxcs` | LXC200, LXC210, LXC211, LXC220, LXC230, LXC240, LXC260 |
| `vms` | VM100, VM102 |
| `all` | All 9 nodes |

## Remote User

A dedicated `ansible` user exists on every managed node:

- SSH key from LXC250 (`~/.ssh/id_ed25519.pub`) in `~/.ssh/authorized_keys`
- NOPASSWD sudo via `/etc/sudoers.d/ansible`
- Bootstrapped via `ansible/playbooks/bootstrap-ansible-user.yml` (one-time, run as root)

## Ansible Vault

Secrets are encrypted with Ansible Vault (AES-256).

- **Vault password file:** `~/.vault_pass` on LXC250 (chmod 600, gitignored)
- **Auto-loaded:** `vault_password_file = ~/.vault_pass` in `ansible.cfg`
- **Encrypted values:** `ansible/inventory/group_vars/all/vault.yml`
- **Format:** inline `!vault |` strings (per-variable encryption, not whole-file)

Current vault variables:

| Variable | Used by |
|---|---|
| `vault_paperless_dbhost` | `paperless-env` role |
| `vault_paperless_dbpass` | `paperless-env` role |
| `vault_paperless_secret_key` | `paperless-env` role |

**Re-encryption process** (inline vault format cannot use `ansible-vault rekey`):

1. Read plaintext: `ansible <host> -m debug -a "var=vault_xxx"`
2. Update `~/.vault_pass` with new password
3. Re-encrypt: `ansible-vault encrypt_string '<plaintext>'`
4. Replace value in `vault.yml`

See: [CLAUDE.md — Vault password changed](../../CLAUDE.md)

## Configuration

`ansible/ansible.cfg`:

- `inventory = inventory/hosts.yml`
- `remote_user = ansible`
- `host_key_checking = False`
- `vault_password_file = ~/.vault_pass`
- `roles_path = roles`

## Playbooks

| Playbook | Target | Purpose |
|---|---|---|
| `apt-upgrade.yml` | `lxcs`, `vms` | Rolling apt upgrade, `serial: 1`, `dpkg --verify` post-task |
| `bootstrap-ansible-user.yml` | `all` | One-time: create `ansible` user, deploy SSH key, configure sudoers |
| `node-exporter.yml` | `all:!lxc200` | Deploy `node_exporter` binary + systemd unit |
| `prometheus-config.yml` | `lxc200` | Deploy Prometheus config via Jinja2 template |
| `paperless-env.yml` | `lxc211` | Deploy Paperless `.env` with Vault-managed secrets |
| `ssh-hardening.yml` | `all` | Set `PasswordAuthentication no` + `PermitRootLogin no` via `lineinfile`, reload sshd |

Convention: `serial: 1` on all multi-host playbooks to avoid simultaneous restarts.

## Roles

| Role | Target | What it does |
|---|---|---|
| `node_exporter` | all nodes except LXC200 | Downloads binary, creates systemd unit via Jinja2 template, handler restarts on unit change |
| `prometheus-config` | LXC200 | Renders `prometheus.yml` from Jinja2 template, reloads via `SIGHUP` (no systemd unit) |
| `paperless-env` | LXC211 | Renders `.env` from Jinja2 template with Vault vars, handler runs `docker compose up -d` |
| `ssh-hardening` | all 9 nodes | Sets `PasswordAuthentication no` + `PermitRootLogin no` via `lineinfile`; handler reloads sshd |

## Dry-Run Convention

From roadmap item 7 (SSH hardening) onwards, all playbooks are tested with `--check --diff` before production runs:

```bash
ansible-playbook playbooks/<name>.yml --check --diff
```

## Related Documents

- [LXC250 – DevOps Workstation](../nodes/lxc250.md)
- [LXC200 – Monitoring](../nodes/lxc200.md)
- [LXC211 – Paperless-ngx](../nodes/lxc211.md)
