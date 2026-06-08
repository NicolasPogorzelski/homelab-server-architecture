# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Current Work in Progress

- **Branch:** `feat/ansible-setup`
- **Ansible setup complete:**
  - `ansible/ansible.cfg` — inventory path, remote_user=ansible, host_key_checking=False
  - `ansible/inventory/hosts.yml` — 9 nodes, grouped by function + type (`lxcs`, `vms`)
  - `ansible/inventory/hosts.yml.example` — sanitized version for repo (Tailscale IP placeholders)
  - `hosts.yml` is gitignored (contains real Tailscale IPs)
  - SSH key from LXC250 (`/home/devops/.ssh/id_ed25519.pub`) distributed to all nodes
  - `ansible all -m ping` returns SUCCESS on all 9 nodes
  - Dedicated `ansible` user on all nodes: SSH key + NOPASSWD sudo via `/etc/sudoers.d/ansible`
  - LXC250 (control node) intentionally excluded from inventory

- **Playbooks complete:**
  - `ansible/playbooks/apt-upgrade.yml` — two plays (lxcs/vms), `serial: 1`, `become: true`, `apt clean` after upgrade, `dpkg --verify` post-task (fails on binary corruption, KE-7 guard)
  - `ansible/playbooks/bootstrap-ansible-user.yml` — one-time bootstrap: creates `ansible` user, deploys SSH key, installs sudo, sets NOPASSWD sudoers rule across all 9 nodes
  - Run after every upgrade: `snippets/scripts/lxc-fstrim.sh` on Proxmox host to reclaim thin-pool blocks

- **Roles complete:**
  - `ansible/roles/node_exporter/` — deploys binary via get_url, unarchive, copy; systemd unit via Jinja2 template (`{{ ansible_host }}:{{ node_exporter_port }}`); handler restarts service on unit change; excludes lxc200 (runs node_exporter as Docker container)
  - `ansible/playbooks/node-exporter.yml` — calls role on `all:!lxc200`, `serial: 1`
  - Idempotency verified: `changed=0` on second run across all 8 nodes

- **`prometheus-config` role complete (2026-05-21, corrected 2026-05-28):**
  - `ansible/roles/prometheus-config/tasks/main.yml` — `ansible.builtin.template` with `lstrip_blocks: yes`
  - `ansible/roles/prometheus-config/handlers/main.yml` — `docker compose restart prometheus` (restart re-binds mount after atomic write; SIGHUP insufficient due to inode change)
  - `ansible/roles/prometheus-config/templates/prometheus.yml.j2` — adds `node-proxmox-host` job via `proxmox_host_tailscale_ip` inventory var
  - `ansible/playbooks/prometheus-config.yml` — deploys role to lxc200; dest path corrected to `/opt/monitoring/prometheus/prometheus.yml`
  - All 13 Prometheus targets verified UP after deploy

- **`chrony` role complete (2026-06-08):**
  - `ansible/roles/chrony/tasks/main.yml` — two tasks: `apt` install (`state: present`, `update_cache`) + `service` (`state: started`, `enabled: true`); no template/handler (Debian default config)
  - `ansible/playbooks/chrony.yml` — calls role on `vms`, `serial: 1`, `become: true`
  - Codifies the 2026-06-07 ad-hoc chrony install; applied fleet-wide on VMs (decision: one consistent time daemon, easier maintenance) — replaced `systemd-timesyncd` on vm100 (chrony `Conflicts:` with it)
  - `--check` dry-run failed on the service task (check mode only simulates the install, so the service does not yet exist) — expected check-mode limitation for install→service dependencies; real run + idempotency (`changed=0` on both VMs) verified; `chronyc tracking` confirms sync on vm100 + vm102

- **`breakglass` role complete (2026-06-08):**
  - `ansible/roles/breakglass/tasks/main.yml` — `authorized_key` in a `loop` over `breakglass_pubkeys`, `user: "{{ breakglass_user }}"`, additive (non-exclusive)
  - `ansible/roles/breakglass/defaults/main.yml` — `breakglass_pubkeys: []` (safe no-op default)
  - `inventory/group_vars/vms.yml` — `breakglass_pubkeys` (the `desktop-cachyos` admin pubkey; public key, not Vault)
  - `inventory/host_vars/vm100.yml` / `vm102.yml` — `breakglass_user: gpu` / `storage` (per-host native user)
  - `ansible/playbooks/breakglass.yml` — role on `vms`, `serial: 1`, `become: true`
  - Scope rationale: VMs only — LXCs are reachable via `pct exec`, VMs need SSH break-glass (no guaranteed qemu-guest-agent). Dry-run found the key already present on both `gpu` and `storage` (`changed=0`); role now makes that state declarative

- **`calibre-importer` role complete (2026-06-08):**
  - `ansible/roles/calibre-importer/` — installs `calibre`, deploys `snippets/scripts/calibre-import.sh` (single source of truth) to `/usr/local/bin/`, and a `calibre-import.service` (oneshot) + `calibre-import.timer` (2-min poll); `ansible/playbooks/calibre-import.yml` runs it on lxc220
  - Needed a rw library mount: `pct config 220` → `mp2: /mnt/smb/books-rw → /books-rw` (the web UI mount `mp0 /books` is `:ro`)
  - **Bug found + fixed during deploy:** `calibredb add` on the CIFS library fails `apsw.BusyError: database is locked` even with calibre-web stopped — CIFS does not translate SQLite's `BEGIN EXCLUSIVE` byte-range lock. Verified by control test (CIFS fails / local copy succeeds). Script rewritten to import into a local `/tmp` working copy of `metadata.db`, `tar` new book dirs back, atomic DB swap; no host mount change (`nobrl`) required
  - Verification gotcha: `calibredb list --with-library /books-rw` *also* fails the CIFS lock (returns nothing) — verify by copying `metadata.db` locally and querying that
  - End-to-end verified on the live library (import → file on share at `/books-rw/<Author>/<Title> (id)/` + row in real `metadata.db` → cleanup); timer `enabled`+`active`, idempotent redeploy

- **Ansible Vault setup complete (2026-05-22):**
  - `inventory/group_vars/all/vault.yml` — 3 encrypted Paperless secrets (`vault_paperless_dbhost`, `vault_paperless_dbpass`, `vault_paperless_secret_key`)
  - `~/.vault_pass` on LXC250 (chmod 600, gitignored) — auto-loaded via `ansible.cfg` `vault_password_file`
  - `group_vars/` lives under `inventory/` so playbooks in `playbooks/` resolve it correctly

- **`paperless-env` role complete (2026-05-23):**
  - `ansible/roles/paperless-env/defaults/main.yml` — all non-secret vars (DB config, paths, redis, network, consumer)
  - `ansible/roles/paperless-env/templates/paperless.env.j2` — Jinja2 template referencing Vault vars
  - `ansible/roles/paperless-env/tasks/main.yml` — deploys `.env` via `ansible.builtin.template`, mode `0600`
  - `ansible/roles/paperless-env/handlers/main.yml` — `docker compose up -d` in compose dir
  - `ansible/playbooks/paperless-env.yml` — deploys role to lxc211; idempotency verified (`changed=0` on second run)
  - Note: `docker-compose-plugin` was corrupt on lxc211 (same KE-7 root cause); reinstalled before deploy

- **Vault password changed (2026-05-23):**
  - Inline vault format (`!vault |`) cannot be rekeyed with `ansible-vault rekey` — each value must be re-encrypted individually
  - Process: `ansible lxc211 -m debug -a "var=vault_xxx"` to read plaintext → update `~/.vault_pass` first → `ansible-vault encrypt_string` without `--ask-vault-pass` → rebuild `vault.yml`
  - Reason: using both `vault_password_file` (ansible.cfg) and `--ask-vault-pass` creates two vault IDs both named `default` → conflict
  - Playbook verified idempotent after rekey (`changed=0`)

- **Repo docs updated (2026-05-24):**
  - `docs/platform/ansible.md` — new platform doc: control node, inventory, vault, playbooks, roles, `--check --diff` dry-run convention
  - `docs/nodes/lxc250.md` — Ansible marked active, Ansible Setup section added
  - `docs/nodes/lxc200.md`, `lxc211.md` — Configuration Management sections added
  - `README.md` — Automation section updated, ansible.md linked in Platform docs

- **Session 2026-05-28 (incident + prep):**
  - Hard shutdown incident: high I/O → forced power-off; full recovery; runbook added to `main` via PR #29
  - `fix(prometheus-config)`: dest path corrected to `/opt/monitoring/`, handler SIGHUP → `docker compose restart`, Proxmox host target added; deployed and verified
  - All Docker stack paths discovered and documented in node docs (`docs/nodes/`)
  - Jellyfin on vm100 migrated from git-clone path to `/opt/docker/jellyfin/` — functional test passed
  - Item #9 prep complete: stack path single source of truth established

- **Next session:** 2026-06-07 session closed out — (a) ~~`chrony` role + break-glass SSH key codified~~ ✅ (2026-06-08). Next: (b) work the incident-remediation backlog (see "Known Technical Debt & Gotchas"): ~~service-level monitoring via blackbox_exporter~~ ✅ (2026-06-08); remaining: journald persistence on vm100/vm102, unattended-upgrades decision on vm100, alert tiering by role, stale-key cleanup on `storage` + lxc250. **Open from the 2026-06-08 KE-9 incident:** (1) durable PostgreSQL boot-ordering fix on lxc260 (systemd `After=tailscaled` + wait-for-IP; not `listen_addresses='*'`); (2) paperless on lxc211 crash-loops on Redis `localhost:6379` refused (separate container-network/config fault). openwebui already recovered via the postgres restart. Then resume the Ansible Learning Roadmap at **Item #9 — Docker update workflow playbook**.

- **Ansible Learning Roadmap (in order):**
  1. ~~OS updates playbook~~ ✅
  2. ~~Bootstrap playbook~~ ✅
  3. ~~First role — node_exporter~~ ✅
  4. ~~Jinja2 templates — prometheus-config role~~ ✅
  5. ~~Handlers~~ ✅
  6. ~~Ansible Vault~~ ✅
  7. ~~SSH hardening role — `PasswordAuthentication no`, `PermitRootLogin no`, sshd handler; adopt `--check --diff` as standard dry-run habit from here on~~ ✅
  8. ~~New node onboarding — `ansible/playbooks/onboarding.yml`: 3 plays (bootstrap as root → ssh-hardening → node_exporter); structure complete, real-node test skipped (no available fresh LXC)~~ ✅
  9. Docker update workflow — pull new images, restart compose stacks via Ansible
  10. PostgreSQL provisioning role — create DB + user for new services on LXC260 (replaces manual `psql`)
  11. PostgreSQL backup playbook — `pg_dump` on LXC260, verify output, store locally
  12. Fleet health check playbook — query all nodes, output status overview
  13. CI/CD + ansible-lint (lightweight) — GitHub Actions: `ansible-lint` on push, `--check` against inventory on PR. Keep minimal — no elaborate matrix or multi-stage pipeline.
  14. ~~Molecule — unit testing for Ansible roles~~ **Deferred** — out of scope for the current learning arc; revisit after the Terraform and Kubernetes tracks.

  **Note:** LXC provisioning (creating containers) is intentionally excluded — that belongs to Terraform, which follows as the next learning track after Ansible.

**Next learning track (after Ansible):** Terraform — primarily on **AWS (free tier)** to learn HCL/state/modules on a widely-used provider, plus a thin **Proxmox slice** for the homelab payoff: `terraform apply` → LXC exists → `onboarding.yml` configures it.

**Roadmap after Terraform:** Kubernetes (k3s) basics, then cloud depth and Python. Bash scripting is cross-cutting throughout. Detailed timeline, certifications, and career milestones live in the private global instructions, not in this repo.

**PR Cadence:** Learning-path branches (`feat/ansible-setup`, `feat/terraform-setup`, etc.) are merged to `main` as a whole when the topic is complete — not after individual items. The items within a topic build on each other and form a single coherent arc. Exception: self-contained platform changes unrelated to the learning topic (e.g. runbooks, hotfixes) are split off to their own branch and PRed independently.

## Working Context (Learning Mode)

This repo is a learning vehicle and portfolio piece for a DevOps career transition.
When working on tasks here:

- Explain every CLI flag and every config value — no copy-paste answers.
- For new tools or configs: link to official documentation first, identify
  relevant sections, then implement.
- Root cause before fix: symptom → verification command → diagnosis → fix.
- Small steps, verify before next step.
- When unsure, say so. Don't hallucinate flags, paths, or behavior.
- Code learning (Bash/Python/YAML): blank-file-first. The first draft is written
  from an empty file without AI or copied snippets — AI is used only to review
  afterwards. The goal is active recall, not recognition; the struggle is the point.

OS context: Proxmox host + Debian 12 LXCs. Daily driver is CachyOS (Arch-based).
Commands must be OS-specific — no generic "Linux commands" when behavior differs.

## Commit Policy

- Never add `Co-Authored-By` or any AI attribution trailer to commit messages.
- Never reference AI tools, Claude, or Anthropic in commit messages or documentation.

## Commit Message Format

Conventional Commits with scope required.

**Format:** `<type>(<scope>): <description>`

**Types:** `feat`, `fix`, `docs`, `refactor`, `chore`, `test`, `ci`

**Scopes:**
- Per node: `vm100`, `vm102`, `lxc200`, `lxc210`, `lxc211`, `lxc220`, `lxc230`, `lxc240`, `lxc250`, `lxc260`
- Thematic: `monitoring`, `network`, `docs`, `adr`, `runbook`, `ci`, `repo`, `platform`

**Examples:**
- `feat(lxc260): add PostgreSQL 15 with hardened pg_hba`
- `docs(platform): add tailscale ACL tier0 rules`
- `fix(monitoring): correct grafana datasource url`
- `chore(repo): update validate-repo.sh check 12`

## Validation

Run the repo validation script before committing or opening a PR:

```bash
./scripts/validate-repo.sh
```

This script enforces 12 checks and is also run by CI on every push/PR to `main`. Fix all errors before merging. The checks catch: empty markdown files, broken internal links, committed `.env` files, missing required doc sections, unsanitized Tailscale IPs or tailnet IDs, private keys, missing `.env.example` files, and files outside the allowed directory structure.

## Documentation Audit Rule

Before every commit that touches `docs/` or `ansible/`:

1. Run `./scripts/validate-repo.sh` and fix all errors before staging.
2. Audit all docs touched in this session for content completeness:
   - Required sections present? (`## Access Model`, `## Failure Impact`, `## Configuration Management`)
   - Cross-links to related docs present and correct?
   - Platform Changelog in `CLAUDE.md` updated with today's change?
3. Show audit results to the user before committing — one line per file checked.

This rule applies even if `validate-repo.sh` passes. Structural checks (script) and content checks (this rule) are complementary, not redundant.

## Repository Structure

This is a **documentation and configuration repository** — no application code, no build system, no tests. The content is:

- `docs/` — Architecture, design decisions, node docs, service docs, platform docs
- `docker/` — Docker Compose stacks and `.env.example` files, one directory per service
- `runbooks/` — Operational procedures (must follow the runbook contract)
- `snippets/` — Reference configs and helper scripts (sanitized)
- `scripts/` — Repo tooling (`validate-repo.sh`)
- `ansible/` — Ansible configuration, inventory, playbooks, roles

Only these top-level directories are allowed (enforced by Check 12).

## Documentation Conventions

**Mandatory sections by doc type** (enforced by validation):

| Doc type | Required section |
|---|---|
| `docs/services/*.md` | `## Access Model` (Zero Trust) |
| `docs/nodes/*.md` | `## Failure Impact` |
| `runbooks/**/*.md` (non-README) | `Precondition`, `Verification`, `Failure` |

**Sanitization rules** (enforced by validation):

- Tailscale IPs must use placeholder `<tailscale-ip-nodename>`, never bare `100.x.y.z`
- Tailnet IDs must use placeholder `<tailnet-id>`, never bare `*.ts.net`
- Never commit `.env` files; only `.env.example` files belong in the repo
- Each `docker/` subdirectory with a `docker-compose.yml` must have a `.env.example`

## Architecture

Single-host Proxmox platform. No HA — recovery-oriented design.

**Compute layer:** VM100 (Docker, GPU/NVIDIA) runs media services (Jellyfin, Audiobookshelf) and inference backends (Ollama).

**Storage layer:** VM102 (MergerFS + SnapRAID + Samba). Services access storage over SMB via Tailscale, not LAN.

**Service LXCs** (all Docker-in-LXC unless noted):
- LXC200 – Monitoring (Prometheus + Grafana)
- LXC210 – Nextcloud (native stack: Apache + PHP + MariaDB + Redis)
- LXC211 – Paperless-ngx
- LXC220 – Calibre-Web
- LXC230 – OpenWebUI (AI stack entrypoint)
- LXC240 – Vaultwarden (secrets tier)
- LXC250 – DevOps workstation (Git, Ansible, IaC — no user-facing services)
- LXC260 – PostgreSQL (centralized platform database; all services that need a DB use this)

**Access model:** Zero Trust via Tailscale. No public ingress, no port-forwarding, LAN is untrusted. Nodes are grouped into tags (`tag:tier0`, `tag:tier1`, `tag:tier2`, `tag:monitoring`, `tag:database`, `tag:ai-stack`, etc.) with explicit ACL rules. The ACL policy lives in the Tailscale admin console; `docs/platform/tailscale-acl.md` mirrors the intended model.

**Binding rule:** Services bind to the Tailscale IP directly, or to loopback and proxied via `tailscale serve`. Never to LAN interfaces.

## Known Technical Debt & Gotchas

Do not flag these as new issues — they are documented tradeoffs or known quirks:

- **LXC220 (Calibre-Web):** UID mapping requires `chown 100000:100000` on mounted storage.
- **LXC240 (Vaultwarden):** SQLite on CIFS is a known limitation, documented as tech debt.
- **Grafana admin password:** only read on first container start. Reset via
  `grafana-cli admin reset-admin-password`.
- **Tailscale Serve HTTPS/HTTP mismatch:** fix with `tailscale serve off` + reconfigure.
- **`network_mode: host` + Docker:** no Docker DNS resolution, use `127.0.0.1`
  instead of container names.
- **VM100 Jellyfin CUDA:** requires `pid: "host"` in docker-compose for
  NVIDIA Container Toolkit access.
- **Service-level monitoring (KE-8 gap — REMEDIATED 2026-06-08):** previously
  alerting covered only `NodeDown` (node_exporter) + disk, not service ports.
  Now `blackbox_exporter` on lxc200 probes 7 services (HTTP + Serve-HTTPS) with a
  `ServiceDown` rule; Tailscale ACL Rule 1c grants monitoring the service ports.
  First run already caught paperless + openwebui returning 502 (dead backends).
- **journald not persisting logs on vm100/vm102 (gap, fix planned):** despite
  `/var/log/journal`, recent boots' logs were lost (see KE-8); forensics fell
  back to wtmp / apt-dpkg text logs / Docker JSON / Prometheus. Remediation:
  investigate `Storage=` / `SystemMaxUse`.
- **unattended-upgrades active on vm100 (uncontrolled change):** installs
  packages incl. kernels autonomously, outside the Ansible `apt-upgrade.yml`
  workflow — on a GPU node this risks kernel/NVIDIA-DKMS coupling after the next
  reboot. Decision pending: disable, or restrict to security-only + exclude kernels.
- **MergerFS pool ~96% full on vm102 (by design):** the media archive is meant
  to fill; read-only consumers (Jellyfin/ABS/Calibre) are unaffected, but write
  consumers (Nextcloud/Paperless/Vaultwarden/Postgres-backups) will eventually
  hit `ENOSPC` — capacity expansion is the lever, not deletion. The `<15% free`
  disk alert on archive disks is largely non-actionable (alert tiering by role pending).

## Platform Changelog

Significant platform changes, in reverse chronological order. Detailed ACL changes are in `docs/platform/tailscale-acl.md#changelog`.

| Date | Change |
|---|---|
| 2026-06-08 | Ansible `calibre-importer` role (LXC220): auto-imports ebooks dropped into `/books-rw/_import` via a `calibre-import.timer` (2-min poll) + `calibredb`. Required a new rw mount `mp2: /mnt/smb/books-rw → /books-rw` (the web UI's `/books` is ro). Hit `apsw.BusyError: database is locked` on `calibredb add` — root cause **CIFS SQLite byte-range locking** (verified: add fails on CIFS, succeeds on a local copy; mount has no `nobrl`). Fix without touching the host mount: import into a local copy of `metadata.db` under `/tmp`, `tar` new book dirs back to CIFS, atomic `metadata.db` swap, container stopped only during the critical section. End-to-end verified (test book imported into the real 2178-book library, then removed) |
| 2026-06-08 | Incident (found by blackbox on first run, KE-9): PostgreSQL on lxc260 bound only loopback after the morning boot — it started before the Tailscale interface had its IP, so it never bound `<tailscale-ip>:5432` despite `listen_addresses` listing it. Remote DB consumers failed: openwebui crash-looped (peewee migration `UnboundLocalError`), paperless 502. `pg_up=1` was misleading (local exporter). Fixed by `systemctl restart postgresql` (binds Tailscale IP now); openwebui recovered. Pending: durable systemd boot-ordering fix (not `listen_addresses='*'` — violates bind rule). Separate open fault: paperless crash-loops on Redis `localhost:6379` refused |
| 2026-06-08 | blackbox_exporter deployed on lxc200 (service-level monitoring, KE-8 remediation): container in monitoring stack, `blackbox.yml` (http_2xx + http_service_up modules), two relabel-based scrape jobs in `prometheus.yml.j2` probing 7 services (Jellyfin/ABS over HTTP on vm100; Paperless/OpenWebUI/Nextcloud/Calibre/Vaultwarden over Serve-HTTPS), `ServiceDown` alert rule. Required Tailscale ACL Rule 1c (monitoring → service ports). Verified: 5/7 UP; paperless + openwebui correctly detected DOWN (502 from `tailscale serve` = dead backend — a real outage to fix separately, exactly the KE-8 gap) |
| 2026-06-08 | Ansible `breakglass` role: codifies the admin break-glass SSH key (`desktop-cachyos`) onto each VM's native user (`gpu`/`storage`) via `authorized_key` loop; `breakglass_pubkeys` (group var, public key — no Vault) + `breakglass_user` (host var). Scope VMs only (LXCs reachable via `pct exec`). Additive/non-exclusive; dry-run found the key already present on both VMs (`changed=0`), role makes it declarative. Closes the 2026-06-07 ad-hoc break-glass item |
| 2026-06-08 | Ansible `chrony` role: installs `chrony` + ensures started/enabled on `vms` (`serial: 1`); codifies the 2026-06-07 ad-hoc install. Applied fleet-wide — replaced `systemd-timesyncd` on vm100 (vm100 was already synced via timesyncd; standardized on one time daemon for maintenance). No template/handler (Debian default config). `--check` revealed the install→service check-mode limitation; real run idempotent (`changed=0` both VMs), `chronyc tracking` confirms sync |
| 2026-06-07 | Investigated the 2026-06-06 VM100 media-services hang (Jellyfin + Audiobookshelf unreachable, recovered by restart). Root cause unconfirmed; proven NOT storage-full / VM102-down / network / hard-CIFS-hang / GPU / resource-exhaustion — node stayed healthy and reachable throughout (Prometheus `up` = 1, 300/300 samples). Exposed two observability gaps now tracked as tech debt (no service-level monitoring; journald not persisting logs). Documented as KE-8 |
| 2026-06-07 | vm102 hygiene (ad-hoc via Ansible; role codification pending): installed `chrony` — node had no time daemon (`NTP service: n/a`, clock unsynchronized, drifting on RTC/hypervisor only; risk for SnapRAID timestamp-based change detection, `SnapRAIDSyncStale` alert math, and cross-node log correlation), now `synchronized: yes`. Break-glass SSH: `desktop-cachyos` admin pubkey added to `storage` `authorized_keys` as fallback alongside the `ansible` user (`PasswordAuthentication no` → key presence is the only access lever) |
| 2026-05-28 | Ansible `ssh-hardening` role: `PasswordAuthentication no` + `PermitRootLogin no` via `lineinfile` on all 9 nodes; `vm102` had `PermitRootLogin yes` explicitly set — remediated; idempotency verified; `--check --diff` dry-run convention adopted |
| 2026-05-23 | Ansible `paperless-env` role: Jinja2 template deploys `.env` with Vault-managed secrets to lxc211; `group_vars/` moved to `inventory/group_vars/` (correct resolution path for playbooks in subdirectory); `docker-compose-plugin` corrupt on lxc211 (KE-7 root cause), reinstalled; idempotency verified |
| 2026-05-22 | Ansible Vault: `vault_password_file` added to `ansible.cfg`; `inventory/group_vars/all/vault.yml` with 3 encrypted Paperless secrets |
| 2026-04-28 | Ansible `node_exporter` role: binary deployment via `get_url` + `unarchive`, systemd unit via Jinja2 template, handler on unit change; deployed to 8 nodes (`all:!lxc200`); idempotency verified; `roles_path` added to `ansible.cfg` |
| 2026-04-27 | Bootstrap playbook: `ansible` user created on all 9 nodes (SSH key + NOPASSWD sudo); `remote_user` switched from `root`/`gpu`/`storage` to `ansible` fleet-wide; `apt-upgrade.yml` updated accordingly |
| 2026-04-26 | LXC220 post-KE-7 recovery: `docker-ce` + `containerd.io` binaries corrupt (`dockerd`, `runc`, `ctr`); reinstalled via `apt-get install --reinstall`; stale containerd task state cleared via `docker rm -f` + `docker compose up -d`; Calibre-Web restored; KE-7 updated; `apt-upgrade.yml` extended with `dpkg --verify` post-task |
| 2026-04-25 | LVM thin-pool overflow (100%): platform-wide incident; VM102 io-error, corrupt packages on LXC230/LXC260 (tailscaled, bash); recovered via apt clean + nsenter fstrim; pool freed to 82.7%; `apt-upgrade.yml` playbook deployed (serial: 1); KE-7 documented |
| 2026-04-25 | Ansible: `lxcs` + `vms` inventory groups added; `NOPASSWD` sudo for `gpu`/`storage` users on VM100/VM102 |
| 2026-04-24 | Ansible initial setup: `ansible.cfg`, `hosts.yml` (9 nodes), SSH key distributed, `ansible all -m ping` verified |
| 2026-04-23 | SnapRAID automation: `snapraid-maintenance.sh` deployed on VM102 (daily sync 02:00, monthly scrub 1st/03:00); `SnapRAIDSyncStale` + `SnapRAIDScrubStale` alert rules added; textfile collector required on VM102 |
| 2026-04-22 | `postgres_exporter` v0.19.1 deployed on CT260 (port 9187, systemd); `PostgreSQLDown` + `PostgreSQLConnectionsHigh` alert rules added; node_exporter fleet (v1.11.1, systemd) deployed across all 10 nodes; all 13 Prometheus scrape targets UP; ACL Rule 1b extended to include port 9187; KE-6 documented |
| 2026-04-21 | Alertmanager deployed on LXC200: Discord webhook receiver, `tailscale serve --https=9093`, 4 active alert rules; `PostgreSQLBackupStale` fixed via textfile collector pattern |
| 2026-04-21 | `chore/repo-review`: SnapRAID runbooks added; Jellyfin + ABS service docs created; KE-4/KE-5 documented; onboarding examples, cross-links, and naming inconsistencies resolved |
| 2026-04-10 | LXC211 Paperless-ngx fully onboarded: `tag:tier1`, Tailscale Serve HTTPS, PostgreSQL on CT260, E2E verified |
| 2026-03-25 | LXC230 OpenWebUI fully onboarded: `tag:ai-stack`, Tailscale Serve HTTPS, PostgreSQL on CT260, Ollama backends (VM100 + Gaming PC), E2E verified |
| 2026-03-20 | LXC260 PostgreSQL platform service added: `tag:database`, centralized DB for all future service consumers |
| 2026-03-09 | `tag:monitoring` formalized in ACL; Rule 1b (monitoring scrape on port 9100) added following container-restart incident (DD#11) |
| 2026-03-04 | LXC250 DevOps workstation added: `tag:admin`, Git + Ansible + IaC, SSH-only (no user-facing services) |

## Adding a New Service

1. Before implementation: link official upstream docs, identify relevant sections, wait for confirmation
2. Create `docs/services/<service>.md` with an `## Access Model` section referencing `docs/platform/tailscale-acl.md`
3. Create `docs/nodes/<node>.md` with a `## Failure Impact` section
4. Add the node's Tailscale tag to `docs/platform/tailscale-acl.md` (tier model, tag ownership, ACL rules, access matrix, changelog)
5. If Docker-based: add `docker/<service>/docker-compose.yml` and `docker/<service>/.env.example`; use pinned version tags (not `:latest`)
6. Run `./scripts/validate-repo.sh` and fix all errors
