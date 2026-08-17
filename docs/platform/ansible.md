# Ansible Platform

This document describes the Ansible setup used to manage the homelab platform.

## Control Node

**LXC250** (`/home/devops/git/homelab-server-architecture/ansible/`)

All playbooks and roles are run from LXC250 over SSH via Tailscale. No direct LAN access is used.

### The control node's checkout tracks `main`, and only `main`

Playbooks are executed from the working tree, not from a commit. A control node parked on a
feature branch, or left mid-merge, silently runs whatever happens to be on disk. That is how a
role can be fixed in the repo and still not take effect on the fleet.

Rules:

- The checkout stays on `main` and is `git pull --ff-only`-ed before a run. `--ff-only` refuses to
  invent a merge commit on a node that should only ever consume history.
- Feature work happens on a workstation, not here.
- Before any run that changes live state, confirm the tree is clean and conflict-free:

  ```bash
  git -C ~/git/homelab-server-architecture status --short --branch
  grep -rlE "^(<<<<<<<|=======|>>>>>>>)" ~/git/homelab-server-architecture/ansible/
  ```

  The second command must print nothing. `validate-repo.sh` Check 15 catches conflict markers that
  reach a commit; nothing catches markers sitting in an uncommitted working tree.

On 2026-07-09 the control node was found on a documentation feature branch with
`.git/MERGE_HEAD` present and conflict markers in three documentation files - a `git merge origin/main`
abandoned partway. The `ansible/` subtree happened to be conflict-free and current, so runs from it
were correct, but that was luck rather than design. Resolved by aborting the merge (the branch's five
commits were already pushed to `origin`, so nothing was lost) and checking out `main`.

## Inventory

- **File:** `ansible/inventory/hosts.yml` (gitignored - contains real Tailscale IPs)
- **Example:** `ansible/inventory/hosts.yml.example` (sanitized, committed)
- **9 managed nodes:** VM100, VM102, LXC200, LXC210, LXC211, LXC220, LXC230, LXC240, LXC260
- **LXC250 excluded** from inventory (control node does not manage itself)

Groups:

| Group | Members |
|---|---|
| `lxcs` | LXC200, LXC210, LXC211, LXC220, LXC230, LXC240, LXC260 |
| `vms` | VM100, VM102 |
| `docker` | LXC200, LXC211, LXC220, LXC230, LXC240, VM100 |
| `database` | LXC260 |
| `all` | All 9 nodes |

The `docker` group holds the nodes running Docker Compose stacks (excludes LXC210 Nextcloud - native Apache/PHP, LXC260 PostgreSQL - native systemd, and VM102 storage). It is the target of `docker-compose-update.yml`.

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
| `vault_paperless_dbhost` | `paperless_env` role |
| `vault_paperless_dbpass` | `paperless_env` role |
| `vault_paperless_secret_key` | `paperless_env` role |

**Re-encryption process** (inline vault format cannot use `ansible-vault rekey`):

1. Read plaintext: `ansible <host> -m debug -a "var=vault_xxx"`
2. Update `~/.vault_pass` with new password
3. Re-encrypt: `ansible-vault encrypt_string '<plaintext>'`
4. Replace value in `vault.yml`

See: [CLAUDE.md - Vault password changed](../../CLAUDE.md)

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
| `chrony.yml` | `vms` | Install `chrony`, ensure started + enabled (time sync on VMs) |
| `breakglass.yml` | `vms` | Deploy break-glass admin SSH key(s) to each VM's native user (`gpu`/`storage`) |
| `docker-compose-update.yml` | `docker` | `docker compose pull` + `up` per stack via `docker_compose_v2` (`pull: always`), `serial: 1` |
| `postgresql-provisioning.yml` | `database` | Declarative tenant onboarding: DB + user + grants + `pg_hba` `hostssl` line + reload, looping over `postgres_tenants` |
| `pg-backup.yml` | `database` | Deploy pg-backup infrastructure to LXC260: `pg-backup.sh` script, textfile collector directory, `pg-backup.service` + `pg-backup.timer` (03:00, `Persistent=true`); removes the legacy cron entry |
| `mariadb-backup.yml` | `lxc210` | Deploy mariadb-backup infrastructure to LXC210: `mariadb-backup.sh` script, textfile collector directory, `mariadb-backup.service` + `mariadb-backup.timer` (03:30, `Persistent=true`, `RandomizedDelaySec=300`). Asserts `/mnt/backups` is a CIFS mount and refuses to deploy otherwise. Targets the host by name, not the `services` group - lxc211 is in that group and runs no database of its own |
| `calibre-import.yml` | `lxc220` | Deploy Calibre auto-import service via `calibre_importer` role (systemd oneshot + 2-min timer) |
| `fleet-health-check.yml` | `all` | Query all nodes for uptime, RAM, mounts, Docker state; write Markdown report |
| `onboarding.yml` | new nodes | Three-play node onboarding: bootstrap as root -> ssh_hardening -> node_exporter |
| `postgresql-boot-order.yml` | `database` | Deploy Tailscale boot-ordering fix to LXC260 via `postgresql_boot_order` role |
| `homelab-schedule.yml` | `proxmox` | Deploy power-schedule scripts + cron file to Proxmox host via `homelab_schedule` role |
| `postgres-exporter.yml` | `database` | Own `postgres_exporter.service` so it binds the Tailscale IP instead of `*:9187` |
| `systemd-hygiene.yml` | `all` | Mask or remove per-host units that sit permanently in `failed`, so `SystemdUnitFailed` stays actionable |
| `tailscale-cert.yml` | `tailscale_cert_ondisk` | Renew the on-disk Tailscale cert and reload the consuming service only when the cert actually changed (KE-16) |
| `unattended-upgrades.yml` | `vm100` | Restrict `unattended-upgrades` to security pockets; blacklist kernel + NVIDIA packages |
| `snapraid-maintenance.yml` | `vm102` | Deploy `snapraid-maintenance.sh` + sync/scrub timers; remove `/etc/cron.d/snapraid` |
| `paperless-inbox-scan.yml` | `lxc210` | Deploy `scan-paperless-inbox.sh` + hourly timer; remove the legacy root crontab entry |
| `jellyfin-watchdog.yml` | `vm100` | Deploy `jellyfin-cuda-watchdog.sh` + monotonic 30-min timer; remove the legacy root crontab entry |

Convention: `serial: 1` on all multi-host playbooks to avoid simultaneous restarts.

## Roles

| Role | Target | What it does |
|---|---|---|
| `node_exporter` | all nodes except LXC200 | Downloads binary (guarded by a `--version` probe, so a converged node skips the download entirely), creates systemd unit via Jinja2 template, handler restarts on unit change. Enables the textfile collector fleet-wide (`node_exporter_textfile_dir`, default-on - it used to default to `""`, which silently dropped vm102's SnapRAID metrics on first rollout) and the systemd collector (`node_systemd_unit_state`, feeding `SystemdUnitFailed`). `.mount` units are deliberately *not* excluded, unlike node_exporter's stock exclude list - mount faults are the failure class the collector was added for. Backslashes in the exclude regex are doubled in the template because systemd applies escape processing to `ExecStart=` arguments |
| `prometheus_config` | LXC200 | Renders `prometheus.yml` from Jinja2 template, handler restarts Prometheus container (`docker compose restart`) to avoid bind-mount inode staleness on atomic writes |
| `paperless_env` | LXC211 | Renders `.env` from Jinja2 template with Vault vars, handler runs `docker compose up -d` |
| `ssh_hardening` | all 9 nodes | Sets `PasswordAuthentication no` + `PermitRootLogin no` via `lineinfile`; handler reloads sshd |
| `chrony` | VMs (vm100, vm102) | Installs `chrony` (`state: present`), ensures service started + enabled; no template/handler (Debian default config) |
| `breakglass` | VMs (vm100, vm102) | Enforces the admin break-glass pubkeys (`breakglass_pubkeys`, group var) on each host's native user (`breakglass_user`, host var). One `authorized_key` call with `exclusive: true` and the keys joined by a newline - *not* a `loop`, which with `exclusive: true` would leave only the last key, and *not* an inline `join("\n")`, which yields a literal `\n` and would have written both keys onto one line. The pre-existing file is preserved once as `authorized_keys.pre-ansible`. Safe empty default (a `when:` guard, so an empty list cannot wipe access) |
| `calibre_importer` | LXC220 | Installs `calibre`, deploys `calibre-import.sh` + a systemd oneshot service & 2-min timer that auto-imports ebooks dropped into `/books-rw/_import` |
| `postgresql_boot_order` | LXC260 | systemd drop-in (`After=`/`Wants=tailscaled.service`) + `wait-for-tailscale-ip.sh` as `ExecStartPre` so PostgreSQL binds its Tailscale IP on boot (KE-9 fix); handler runs `daemon-reload` |
| `docker_compose_update` | `docker` group (LXC200/211/220/230/240, VM100) | Loops over per-host `compose_projects` (list var in `host_vars/`), runs `community.docker.docker_compose_v2` with `pull: always` + `recreate: auto` - pulls new images and recreates only changed stacks; safe empty default (`compose_projects: []`) keeps the role a no-op on hosts without stacks |
| `postgresql_provisioning` | LXC260 (`database`) | Declarative DB tenant onboarding via `community.postgresql` modules (`postgresql_db`/`_user`/`_privs`/`_pg_hba`), looping over `postgres_tenants`. Connects via peer auth (`become_user: postgres`); installs `acl` so the unprivileged-become temp-file handoff works; passwords come from Vault via a separate `postgres_tenant_passwords` dict kept out of the loop item (so a task failure can't leak them), read only by the `no_log` user task. `pg_hba` change notifies a `reload` handler. Safe empty default (`postgres_tenants: []`) |
| `postgresql_backup` | LXC260 (`database`) | Deploys `pg-backup.sh` from `snippets/postgres/` (`copy` module) and schedules it with `pg-backup.service` (`Type=oneshot`, `User=postgres`) + `pg-backup.timer` (`OnCalendar=*-*-* 03:00:00`, `Persistent=true`). Removes the legacy `postgres`-user cron job it replaced: cron had silently skipped every run for 26 days because `homelab_schedule` powers the host down before 03:00. The script now refuses to run unless `findmnt -no FSTYPE /mnt/backups` reports `cifs` - testing that the directory merely *exists* was the original defect |
| `homelab_schedule` | Proxmox host (`proxmox`) | Deploys `homelab-setwake.sh` + `homelab-shutdown.sh` to `/usr/local/sbin/` and manages `/etc/cron.d/homelab-schedule` via template. Source scripts: `ansible/roles/homelab_schedule/files/homelab-setwake.sh` + `.../homelab-shutdown.sh` (role-local `files/`, not repo-root `scripts/`). Note: Proxmox host uses `ansible_user: root` - no `ansible` user bootstrapped there. Not yet applied. |
| `postgres_exporter` | LXC260 (`database`) | Owns `postgres_exporter.service` so `ExecStart` carries `--web.listen-address={{ ansible_host }}:9187` instead of binding `*:9187`. Orders `After=`/`Wants=tailscaled.service` (the KE-9/KE-12 bind race). `assert`s that the hand-installed binary and `/etc/postgres_exporter.env` exist rather than deploying a unit that cannot start; the env file holds `DATA_SOURCE_NAME` and stays unmanaged until there is a Vault step for it |
| `systemd_hygiene` | `all` | Units that sit permanently in `failed` and drown out real faults now that `SystemdUnitFailed` alerts on unit state. Two sources, concatenated by a `set_fact` at the top of the role: `systemd_hygiene_masked_units` per host (lxc210 `run-rpc_pipefs.mount`, lxc260 `nvmf-autoconnect`/`openipmi`, vm100's legacy mount units) and `systemd_hygiene_group_units` per group (`group_vars/lxcs.yml`: the `postfix-resolvconf` pair). The split is not cosmetic - a condition that belongs to the platform would otherwise be restated in seven host_vars files, and Ansible does not merge two variables of the same name, so a host defining the per-host list would silently drop the fleet-wide entries. Each entry names a `reason` and an `action`: `mask` for package-owned units, `remove` for hand-written ones - `systemctl mask` refuses to overwrite an existing unit file. Finishes with `reset-failed` |
| `tailscale_cert` | `tailscale_cert_ondisk` (lxc210) | Runs `tailscale cert --min-validity 720h` from a timer (`04:30`, `Persistent=true`) and reloads the consuming service only when the cert's `sha256sum` changed. `tailscale serve` renews per-connection; a service that reads the cert from disk does not, and Apache caches it in memory - lxc210 served an expired certificate that had already been renewed on disk (KE-16) |
| `unattended_upgrades` | VM100 | Drop-in `52-homelab-unattended.conf` restricting `Allowed-Origins` to the security pockets and blacklisting `linux-image`/`linux-headers`/`linux-generic`/`linux-modules`/`nvidia-`/`libnvidia-`. The `#clear` directives are load-bearing: APT appends to a list option when it is redeclared, so without them the regular archive stays enabled. Validated with `apt-config -c %s dump` before install. Ubuntu-specific origin ids - vm100 is the only non-Debian node |
| `snapraid_maintenance` | VM102 | Deploys `snapraid-maintenance.sh` and schedules it via the template unit `snapraid-maintenance@.service` (`ExecStart=... %i`, so one unit file serves both instances) driven by `snapraid-sync.timer` (daily 23:00) and `snapraid-scrub.timer` (monthly, 1st at 20:00), both `Persistent=true`. Deletes `/etc/cron.d/snapraid`, whose 23:00 sync was skipped without a trace on every night the host powered down first |
| `paperless_inbox_scan` | LXC210 | Deploys `scan-paperless-inbox.sh` + `paperless-inbox-scan.timer` (`OnCalendar=hourly`, `Persistent=true`) and removes the hand-written root crontab entry |
| `jellyfin_watchdog` | VM100 | Deploys `jellyfin-cuda-watchdog.sh` + a monotonic timer (`OnBootSec=5min`, `OnUnitActiveSec=30min`). No `Persistent=` - it applies only to `OnCalendar=` timers, and a poll missed while the host was off has nothing to catch up on. Removes the hand-written `*/30 * * * *` root crontab entry |

**Two conventions that these roles share, both learned the hard way on 2026-07-10:**

1. *Scheduling is a systemd timer with `Persistent=true`, never a cron entry.* The Proxmox host
   powers down overnight, so cron silently loses every slot it sleeps through and never retries.
   Timers also surface a failed run through `SystemdUnitFailed`; a failing cron job is invisible.
   The single exception is `homelab_schedule` on the host, which *is* the shutdown trigger.
2. *A role that cannot be dry-run cannot be reviewed.* Read-only probes carry `check_mode: false`
   so their `register`ed value exists under `--check`; `systemctl enable` on a freshly templated
   unit carries `when: not ansible_check_mode`, because in check mode the unit file was never
   really written and systemd would fail with "Could not find the requested service".

## SSH Hardening

All 9 managed nodes are hardened via the `ssh_hardening` role:

| Directive | Value | Reason |
|---|---|---|
| `PasswordAuthentication` | `no` | Eliminates brute-force attack vector; SSH keys are already deployed fleet-wide |
| `PermitRootLogin` | `no` | Root SSH access is unnecessary - `ansible` user has NOPASSWD sudo |

**Implementation:** `ansible.builtin.lineinfile` sets each directive directly in `/etc/ssh/sshd_config`. The handler reloads sshd (`state: reloaded`) without dropping active sessions.

**Pre-existing finding:** `vm102` had `PermitRootLogin yes` explicitly set (not default). Remediated by this role (2026-05-28).

## Dry-Run Convention

From roadmap item 7 (SSH hardening) onwards, all playbooks are tested with `--check --diff` before production runs:

```bash
ansible-playbook playbooks/<name>.yml --check --diff
```

## Related Documents

- [LXC250 - DevOps Workstation](../nodes/lxc250.md)
- [LXC200 - Monitoring](../nodes/lxc200.md)
- [LXC211 - Paperless-ngx](../nodes/lxc211.md)
