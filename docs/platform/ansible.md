# Ansible Platform

Every node of the platform - the Proxmox host and its nine guests - is managed by Ansible from
the control node lxc250. The catalogue of playbooks and roles follows; node membership
lives in `ansible/inventory/hosts.yml.example`, schedules in each role's `defaults/main.yml`.

## Control Node

lxc250 ([node document](../nodes/lxc250.md)) holds the checkout under
`/home/devops/git/homelab-server-architecture/ansible/`, the vault password and the real
inventory. Playbooks reach every node over SSH on the tailnet; nothing is run over the LAN.

### The control node's checkout tracks `main`, and only `main`

Playbooks run from the working tree, not from a commit, so a checkout parked on a feature branch
or left mid-merge runs whatever is on disk.

- The checkout stays on `main` and is updated with `git pull --ff-only`. Feature work happens on a
  workstation.
- `ansible/playbooks/preflight.yml` is imported as the first play of every playbook that changes
  live state. It fetches, then refuses the run unless the tree is a clean `main` equal to
  `origin/main` with no merge conflict marker under `ansible/`. An override takes a reason string
  and prints it into the run output.
- Read-only playbooks (`fleet-health-check.yml`, `fleet-snapshot.yml`) do not import it, so
  diagnosis stays available during an incident.

## Inventory

- **File:** `hosts.yml` beside the example (gitignored, holds the real addresses).
- **Example:** `ansible/inventory/hosts.yml.example` (sanitized, committed; owner of node and group
  membership).
- **Managed nodes:** 10 - the Proxmox host and nine guests, lxc250 among them.

| Group | Members |
|---|---|
| `lxcs` | lxc200, lxc210, lxc211, lxc220, lxc230, lxc250, lxc260 |
| `vms` | vm100, vm102 |
| `guests` | `lxcs` + `vms`: every node except the hypervisor; the target of every sweeping playbook |
| `docker` | lxc200, lxc211, lxc220, lxc230, vm100 (nodes running Compose stacks) |
| `database` | lxc260 |
| `proxmox` | the Proxmox host; connects as `root` |
| `tailscale_cert_ondisk` | lxc210 (reads its Tailscale certificate from disk, see KE-16) |
| `offsite_sources` | vm102, lxc250 |
| `all` | `guests` + `proxmox`; used only by read-only or explicitly host-safe playbooks |

### Why sweeps target `guests` and not `all`

`all` once excluded lxc250 silently because it belonged to no group. Since the hypervisor joined
the inventory, a play written with `hosts: all` would also reach the machine that runs every
guest. State-changing sweeps therefore target `guests`, and reach the hypervisor through a second,
named `proxmox` play where the role has been checked for it (`ssh-hardening.yml`,
`node-exporter.yml`, `systemd-hygiene.yml`, `tailscale-boot-gate.yml`, `lan-guard.yml`).

## Remote User

- Guests: a dedicated `ansible` user with the control node's key and NOPASSWD sudo via
  `/etc/sudoers.d/ansible`, created once by `bootstrap-ansible-user.yml` connecting as root.
- lxc250 is bootstrapped by `snippets/scripts/bootstrap-ansible-user-lxc250.sh` through `pct exec`,
  because it refuses root SSH logins and the bootstrap play would need the account it creates.
- The Proxmox host has no `ansible` user; the `proxmox` group connects as root with key
  authentication only (`PermitRootLogin prohibit-password`).

## Ansible Vault

Secrets are inline `!vault |` strings in `ansible/inventory/group_vars/all/vault.yml`, encrypted
with the password in `~/.vault_pass` on lxc250 (mode 600, gitignored, loaded by `ansible.cfg`).

| Variable | Used by |
|---|---|
| `vault_paperless_dbhost`, `vault_paperless_dbpass`, `vault_paperless_secret_key` | `paperless_env` |
| `vault_postgres_exporter_dsn` | `postgres_exporter` |
| `vault_jellyfin_api_key` | `jellyfin_watchdog`, `jellyfin_user_prefs` |
| `vault_offsite_backup_repository`, `vault_offsite_backup_password` | `offsite_backup` (not yet defined; the role is not deployed) |

Inline vault strings cannot be rekeyed with `ansible-vault rekey`. To change the password: read
each value (`ansible <host> -m debug -a "var=vault_xxx"`), replace `~/.vault_pass`, re-encrypt
each value with `ansible-vault encrypt_string`, and replace it in `vault.yml`.

## Configuration

`ansible/ansible.cfg` sets `inventory = ./inventory/hosts.yml`, `remote_user = ansible`,
`roles_path = ./roles`, `vault_password_file = ~/.vault_pass` and `host_key_checking = False`.

**Known gap:** `host_key_checking = False` means the control node accepts any SSH host key, so a
host impersonating a node on the tailnet would be handed the run and every secret it deploys. It is
tracked in the [remediation plan](remediation-plan.md).

## Conventions

- **Scheduling:** every scheduled job is a systemd timer with `Persistent=true`, because the host
  powers down nightly and cron loses every slot it sleeps through; a failed run surfaces through
  `SystemdUnitFailed`. The single exception is the shutdown itself (`homelab_schedule`, cron in
  `/etc/cron.d`).
- **Dry run:** every playbook is run with `--check --diff` before it changes live state. Read-only
  probes carry `check_mode: false` so their registered values exist under `--check`; enabling a
  freshly templated unit carries `when: not ansible_check_mode`.
- **Rolling:** the eight multi-host playbooks that restart services (`apt-upgrade`, `breakglass`,
  `chrony`, `docker-compose-update`, `node-exporter`, `pg-backup`, `pg-restore-test`,
  `ssh-hardening`) use `serial: 1` and `max_fail_percentage: 0`.
- **Empty defaults:** roles driven by a per-host list default to an empty list and are a no-op on
  nodes that declare nothing, so a group target stays safe.
- **Drift:** `fleet-drift` runs the playbooks listed in `ansible/drift-sweep.conf` with `--check`
  weekly and counts changes against the baseline in that file.

## Playbooks

| Playbook | Targets | What it does |
|---|---|---|
| `preflight.yml` | `all`, checks run once on the control node | Refuses the run unless the checkout is a clean `main` in sync with `origin`. |
| `apt-upgrade.yml` | `lxcs`, then `vms` | Rolling apt upgrade with a `dpkg --verify` integrity check afterwards. |
| `apt-metrics.yml` | `all` | Applies `apt_metrics`. |
| `auditd.yml` | `proxmox` | Applies `auditd` (exercise). |
| `bootstrap-ansible-user.yml` | `lxcs:!lxc250`, `vm100`, `vm102` | One-time creation of the `ansible` user, key and sudoers rule, connecting as root. |
| `breakglass.yml` | `vms` | Applies `breakglass`. |
| `calibre-import.yml` | `lxc220` | Applies `calibre_importer`. |
| `chrony.yml` | `vms` | Applies `chrony`. |
| `docker-boot-retry.yml` | `docker` | Applies `docker_boot_retry` (opt-in per host). |
| `docker-compose-update.yml` | `docker` | Applies `docker_compose_update`. |
| `docker-mount-ordering.yml` | `docker` | Applies `docker_mount_ordering`. |
| `fleet-drift.yml` | `lxc250` | Applies `fleet_drift`. |
| `fleet-health-check.yml` | `all`, then `docker`, then `localhost` | Read-only report of uptime, RAM, mounts and Docker state into `~/fleet-health/`, kept seven days. |
| `fleet-snapshot.yml` | `all`, then `lxc250` | Read-only record of sockets, unit files, crontabs, mounts and images per node, diffed against the previous run and exported as `fleet_snapshot_*` metrics. |
| `fleet-snapshot-schedule.yml` | `lxc250` | Applies `fleet_snapshot`. |
| `guest-backup.yml` | `proxmox` | Applies `guest_backup`. |
| `homelab-schedule.yml` | `proxmox` | Applies `homelab_schedule`. |
| `jellyfin-user-prefs.yml` | `vm100` | Applies `jellyfin_user_prefs`. |
| `jellyfin-watchdog.yml` | `vm100` | Applies `jellyfin_watchdog`. |
| `journal-central.yml` | `lxc200`, then `guests` | Applies `journal_remote` on the receiver, then `journal_upload` on nodes that opt in (exercise). |
| `journald.yml` | `all` | Applies `journald`. |
| `kernel-panic-policy.yml` | `proxmox` | Applies `kernel_panic_policy`. |
| `lan-guard.yml` | `guests`, then `proxmox` | Applies `lan_guard`. |
| `listener-metrics.yml` | `all` | Applies `listener_metrics`. |
| `mariadb-backup.yml` | `lxc210` | Applies `mariadb_backup`. |
| `mariadb-bind.yml` | `lxc210` | Applies `mariadb_bind`. |
| `mariadb-restore-test.yml` | `lxc210` | Applies `mariadb_restore_test`. |
| `netconsole.yml` | `vm100` | Applies `netconsole` (sending side; the receiver is in `proxmox_host_units`). |
| `netplan-no-ra.yml` | `vm100` | Applies `netplan_no_ra`. |
| `nft-guard.yml` | `guests` | Applies `nft_guard` (no-op unless a node declares ports). |
| `node-exporter.yml` | `guests`, then `proxmox` | Applies `node_exporter`. |
| `nsswitch.yml` | `guests` | Applies `nsswitch` (no-op unless a node declares a resolution order). |
| `offsite-backup.yml` | `offsite_sources` | Applies `offsite_backup`; not yet run, the target is not provisioned. |
| `onboarding.yml` | `lxc-test` (edit for the new node) | Template for a new node: bootstrap as root, then `ssh_hardening`, then `node_exporter`. |
| `paperless-env.yml` | `lxc211` | Applies `paperless_env`. |
| `paperless-inbox-scan.yml` | `lxc210` | Applies `paperless_inbox_scan`. |
| `pg-backup.yml` | `database` | Applies `postgresql_backup`. |
| `pg-restore-test.yml` | `database` | Applies `postgresql_restore_test`. |
| `postgres-exporter.yml` | `database` | Applies `postgres_exporter`. |
| `postgresql-boot-order.yml` | `lxc260` | Applies `postgresql_boot_order`. |
| `postgresql-provisioning.yml` | `database` | Applies `postgresql_provisioning`. |
| `prometheus-config.yml` | `lxc200` | Applies `prometheus_config`. |
| `proxmox-host-units.yml` | `proxmox` | Applies `proxmox_host_units`. |
| `smart-metrics.yml` | `proxmox` | Applies `smart_metrics`. |
| `snapraid-maintenance.yml` | `vm102` | Applies `snapraid_maintenance`. |
| `ssh-hardening.yml` | `guests`, then `proxmox` | Applies `ssh_hardening`; the host play runs last and must report `changed=0`. |
| `storage-permissions.yml` | `vm102` | Applies `storage_permissions`. |
| `systemd-hygiene.yml` | `guests`, then `proxmox` | Applies `systemd_hygiene`; the host has its own play so a fleet-wide entry cannot reach it by accident. |
| `tailscale-boot-gate.yml` | `guests`, then `proxmox` | Applies `tailscale_boot_gate`. |
| `tailscale-cert.yml` | `tailscale_cert_ondisk` | Applies `tailscale_cert`. |
| `timezone.yml` | `all` | Applies `timezone`. |
| `unattended-upgrades.yml` | `guests` | Applies `unattended_upgrades`. |

## Roles

| Role | Targets | What it does |
|---|---|---|
| `apt_metrics` | all nodes | Exports pending package upgrades through Debian's `apt.sh` collector, redirected by drop-in to the fleet's textfile directory, with `TMPDIR` pointed there too. |
| `auditd` | Proxmox host | Exercise ([decision](../decisions/exercise-scope-before-terraform.md)): syscall auditing with a starter rule set, read back with `auditctl -l`, `SYSLOG` actions and a capped log; no alert reads it. |
| `breakglass` | vm100, vm102 | Enforces the admin break-glass keys exclusively on each VM's native user and removes retired passwordless sudo rules. |
| `calibre_importer` | lxc220 | Installs Calibre and a timer that imports ebooks dropped into `/books-rw/_import`. |
| `chrony` | vm100, vm102 | Installs and enables `chrony` with the Debian default configuration. |
| `docker_boot_retry` | `docker` hosts with `docker_boot_retry_enabled` | Once per boot, restarts containers whose start failed with a `State.Error`, which Docker's restart policy never retries. |
| `docker_compose_update` | `docker` | Copies each host's compose files from `docker/` and runs `docker_compose_v2` with `pull: always`; refuses a node whose `.env` lacks a variable the file interpolates. |
| `docker_mount_ordering` | `docker` | Orders `docker.service` after the `.automount` units its containers bind (never the `.mount` units, see KE-15). |
| `fleet_drift` | lxc250 | Weekly timer running the drift sweep as `devops` and exporting the result as a metric. |
| `fleet_snapshot` | lxc250 | Weekly timer running `fleet-snapshot.yml`, ordered before the Saturday host jobs. |
| `guest_backup` | Proxmox host | Weekly `vzdump` of the nine guests to `/mnt/vzdump` (asserted to be a mountpoint off the root device), plus the daily host-config backup and `platform-restore.sh` ([runbook](../../runbooks/platform/platform-restore.md)). |
| `homelab_schedule` | Proxmox host | Renders the RTC wake and shutdown scripts and the one cron line in `/etc/cron.d/homelab-schedule`; wake plans are role variables. |
| `jellyfin_user_prefs` | vm100 | Asserts `SubtitleMode` on every Jellyfin user through the API and reports drifted users under `--check`. |
| `jellyfin_watchdog` | vm100 | Deploys the CUDA watchdog script, its one-minute monotonic timer and a root-only API-key header file. |
| `journal_remote` | lxc200 | Exercise: socket-activated `systemd-journal-remote` bound to the Tailscale address, received journals capped by an hourly vacuum timer. |
| `journal_upload` | guests that opt in (lxc211, lxc260) | Exercise: ships the local journal to lxc200, verified by the upload cursor file. |
| `journald` | all nodes | Pins `Storage=persistent` and size limits by drop-in and reads them back with `journalctl --header`. |
| `kernel_panic_policy` | Proxmox host | Sets `kernel.panic_on_oops=1` and `kernel.panic=10` and reads them back from the running kernel ([KE-21](known-errors.md#ke-21)). |
| `lan_guard` | `guests`, then `proxmox` | nftables table on the LAN interface dropping new inbound connections except replies, ICMP, DHCP, Tailscale UDP and per-node exceptions (SMB to vm102 from vm100 and the host; break-glass SSH and netconsole to the host). |
| `listener_metrics` | all nodes | Exports every listening socket outside loopback and the tailnet that the node's allow list does not name. |
| `mariadb_backup` | lxc210 | Daily MariaDB dump to `/mnt/backups` on a timer; refuses to deploy unless that path is a CIFS mount. |
| `mariadb_bind` | lxc210 | Masks `mariadb.socket` so MariaDB binds loopback, and verifies the listener with `ss`. |
| `mariadb_restore_test` | lxc210 | Monthly restore of the latest dump into a throwaway database, asserting the key Nextcloud tables are non-empty. |
| `netconsole` | vm100 | Loads `netconsole` after `network-online.target`, streaming the kernel log to the host's LAN address ([KE-20](known-errors.md#ke-20)). |
| `netplan_no_ra` | vm100 | Disables IPv6 router advertisements per interface and fails while a global IPv6 address remains. |
| `nft_guard` | nodes declaring `nft_guard_local_only_ports` (lxc210) | nftables table restricting wildcard-bound ports to loopback (Collabora). |
| `node_exporter` | all nodes | Installs `node_exporter` with the textfile and systemd collectors, bound to the Tailscale address behind the boot gate; on lxc200 a second, native instance on 9101 ([decision](../decisions/lxc200-systemd-visibility.md)). |
| `nsswitch` | nodes declaring `nsswitch_hosts` (lxc250) | Owns the `hosts:` line of `/etc/nsswitch.conf` and verifies resolution with `getent` ([decision](../decisions/magicdns-and-systemd-resolved.md)). |
| `offsite_backup` | `offsite_sources` | `restic` to an append-only `rest-server` at a second site; built, not deployed ([decision](../decisions/offsite-backup-target.md)). |
| `paperless_env` | lxc211 | Renders the Paperless `.env` from vaulted values and derives the Serve URL from `tailscale status`. |
| `paperless_inbox_scan` | lxc210 | Hourly timer rescanning the Nextcloud Paperless inbox. |
| `postgres_exporter` | lxc260 | Owns `postgres_exporter.service` bound to the Tailscale address and ordered after `tailscaled`. |
| `postgresql_backup` | lxc260 | Daily `pg_dumpall` on a timer with write-time verification; refuses to run unless `/mnt/backups` is CIFS. |
| `postgresql_boot_order` | lxc260 | Drop-in gating PostgreSQL on the Tailscale address ([KE-9](known-errors.md#ke-9)). |
| `postgresql_provisioning` | lxc260 | Declarative tenant onboarding (database, user, grants, `pg_hba` line) from `postgres_tenants`. |
| `postgresql_restore_test` | lxc260 | Monthly full-cluster restore into a throwaway cluster on port 5433, then teardown. |
| `prometheus_config` | lxc200 | Renders `prometheus.yml` and restarts the Prometheus container on change. |
| `proxmox_host_units` | Proxmox host | Owns `lxc-fstrim`, `lvm-thin-metrics`, `smb-mounts-check` and the netconsole receiver. |
| `smart_metrics` | Proxmox host | Deploys Debian's `smartmon.sh` collector into the host's textfile directory. |
| `snapraid_maintenance` | vm102 | Sync, scrub and status timers driving `snapraid-maintenance.sh`, plus the SnapRAID exclude block ([KE-19](known-errors.md#ke-19)). |
| `ssh_hardening` | all nodes | Renders the `00-hardening.conf` sshd drop-in from a template (and sets the same directives in `sshd_config`), optionally pins `ListenAddress`, and verifies the bind ([decision](../decisions/sshd-listen-address.md)). |
| `storage_permissions` | vm102 | Pre-creates share directories on every branch and exports permission-matrix violations as metrics. |
| `systemd_hygiene` | `guests`, then `proxmox` | Masks or removes units that can never succeed on their node, optionally purges the package that ships them, then `reset-failed`. |
| `tailscale_boot_gate` | nodes declaring `tailscale_boot_gate_units` | Drop-in putting `wait-for-tailscale-ip.sh` in front of units that bind the Tailscale address. |
| `tailscale_cert` | `tailscale_cert_ondisk` | Renews the on-disk Tailscale certificate on a timer and reloads the consumer only when it changed ([KE-16](known-errors.md#ke-16)). |
| `timezone` | all nodes | Sets `Europe/Berlin` and reads it back; on lxc210 also pins MariaDB's `default_time_zone`. |
| `unattended_upgrades` | all guests | Installs `unattended-upgrades`, turns the daily run on and allows the security archive alone, per distribution from `vars/` (`Allowed-Origins` on Ubuntu, `Origins-Pattern` on Debian); kernels are held back, the NVIDIA stack on vm100 too. Reads the merged config back with `apt-config` and asserts it. |

## SSH Hardening

| Directive | Guests | Proxmox host |
|---|---|---|
| `PasswordAuthentication` | `no` | `no` |
| `PermitRootLogin` | `no` | `prohibit-password` (root is the only administrative account; set in `group_vars/proxmox.yml`) |
| `ListenAddress` | pinned to the Tailscale address | unpinned ([decision](../decisions/sshd-listen-address.md)) |

The role picks `restarted` where `ssh.socket` is active and `reloaded` elsewhere
([KE-24](known-errors.md#ke-24)). Where `PermitRootLogin` is `no` it deletes
`/root/.ssh/authorized_keys`. A run against a converged host reports `changed=0`.

## Rolling Playbooks and a Stopped Run

With `serial: 1` and `max_fail_percentage: 0` the first failed host ends the run and later hosts
are not touched.

Verified 2026-10-10: a play failing on the first of three hosts never started the other two.

A stopped run leaves the fleet split. Do not restart the same run blindly: read the recap for the
failed host and task, fix the cause, dry-run with `--check --diff --limit <host>`, apply there,
then rerun without `--limit` - the hosts already done report `ok`. A change that must not stay
half-rolled (a key rotation, a sudo rule) is reverted on the earlier hosts with the previous
commit's version of the playbook, not by hand.

## Related Documents

- [lxc250 - control node](../nodes/lxc250.md)
- [Proxmox host](proxmox-host.md)
- [Remediation plan](remediation-plan.md)
