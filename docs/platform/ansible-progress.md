# Ansible Work-in-Progress Handover

Detailed progress log for the `feat/ansible-setup` learning branch: the completed
roles/playbooks catalog plus per-session narratives. Kept out of `CLAUDE.md` so the
always-loaded instruction context stays small; `CLAUDE.md` carries only the current
status, next step, and the roadmap checklist, and links here.

Append new session notes to this file.

## Completed Setup

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

## Session Narratives

- **Session 2026-05-28 (incident + prep):**
  - Hard shutdown incident: high I/O → forced power-off; full recovery; runbook added to `main` via PR #29
  - `fix(prometheus-config)`: dest path corrected to `/opt/monitoring/`, handler SIGHUP → `docker compose restart`, Proxmox host target added; deployed and verified
  - All Docker stack paths discovered and documented in node docs (`docs/nodes/`)
  - Jellyfin on vm100 migrated from git-clone path to `/opt/docker/jellyfin/` — functional test passed
  - Item #9 prep complete: stack path single source of truth established

- **Session 2026-06-09 (calibre review — done):** reviewed the calibre auto-import architecture against the [ADR](../decisions/calibre-cifs-sqlite-import.md) alternatives — **design kept** (`nobrl` stays rejected; library-on-local-block stays deferred — no block volume, Calibre couples `metadata.db` to the library dir). Review surfaced one real bug in `calibre-import.sh`: source files were deleted *inside* the import loop (right after `calibredb add` into the volatile `/tmp` working copy), i.e. **before** the durable write-back to CIFS — an interrupt between loop and tar-back/DB-swap silently lost the book (node keeps no second copy, MergerFS near full). Fixed: collect successfully-added sources in an array, delete them **only after** tar-back + atomic `metadata.db` swap succeed; an interrupted run leaves sources in `_import` and retries them next timer tick (`--automerge ignore` keeps it idempotent). ADR gained a "Durability ordering" subsection. `bash -n` clean. **Redeploy DONE (2026-06-10):** script was already hash-identical on lxc220 (`34a2861`); converging the role surfaced a separate host-storage incident (rw CIFS mount detached — see 2026-06-10 changelog), fixed; playbook now `changed=0`, timer fired post-fix with `Result=success`. Calibre item fully closed.

- **Next session marker (historical):** 2026-06-07 session closed out — (a) ~~`chrony` role + break-glass SSH key codified~~ ✅ (2026-06-08). Next: (b) work the incident-remediation backlog (see "Known Technical Debt & Gotchas"): ~~service-level monitoring via blackbox_exporter~~ ✅ (2026-06-08); remaining: journald persistence on vm100/vm102, unattended-upgrades decision on vm100, alert tiering by role, stale-key cleanup on `storage` + lxc250. **KE-9 fully closed (2026-06-09):** (1) ~~durable PostgreSQL boot-ordering fix on lxc260~~ ✅ (`postgresql-boot-order` role, reboot-verified); (2) ~~paperless on lxc211 crash-loops on Redis `localhost:6379`~~ ✅ (`paperless-env` role default → `redis://redis:6379`, container healthy, RestartCount 0). openwebui already recovered via the postgres restart. **Next: resume the Ansible Learning Roadmap at Item #9 — Docker update workflow playbook.**

- **Session 2026-06-09b (Item #9 design — DONE, no code yet):** worked the full design of the Docker update workflow playbook (Roadmap #9); decisions locked, ready to build. Captured to devops-til (`ansible/docker-compose-updates.md` + precedence/safe-default additions to `inventory-groups.md`). **Design decisions:** (1) module `community.docker.docker_compose_v2`, chosen for idempotency + structured results (not because `shell` is "too short" — `shell` works but always reports `changed`); (2) `pull: always` is required for updating — the default `pull: policy` delegates to Compose's pull_policy ≈ `missing`, so it will NOT re-pull an already-present tag; `recreate: auto` (default) gives idempotency — recreates only if image/config changed, so `pull: always` + no upstream change still = `changed=0` (pull = "always look", not "always change"); (3) per-host stack paths as a list var `compose_projects` in `host_vars/<node>.yml`, task iterates `loop: "{{ compose_projects }}"` with `project_src: "{{ item }}"` (loop is sequential by default — stacks update one-by-one for free); (4) scope = new inventory group `docker` (`hosts: docker`), `serial: 1` (homelab resource limits). **Build steps remaining (resume here):** (a) **verify which nodes actually run Compose** — `ansible all -m shell -a 'docker compose ls 2>/dev/null || echo NO-DOCKER'` (NOT all nodes: LXC210 Nextcloud is native Apache/PHP, LXC260 PostgreSQL is native systemd — likely out; confirm vm102); (b) **verify real compose paths** per node from `docs/nodes/<node>.md` (single source of truth) cross-checked against `docker compose ls`; (c) **first file Nicolas types himself** (new concept-art, blank-file-first): the `docker` group in `hosts.yml` + first `host_vars/<node>.yml` with `compose_projects`; then the playbook/role with the `docker_compose_v2` task; (d) add safe no-op default `compose_projects: []` in role `defaults/main.yml`. **Open checkpoint to ask Nicolas on resume:** why the empty default belongs in `defaults/main.yml` and not `group_vars/all` (role reusability across projects). Watch-out: `docker ... --format '{{...}}'` collides with Jinja2 when run via `ansible -a`; `ansible.cfg` is CWD-relative (run from the `ansible/` dir).

- **Session 2026-06-11 (Item #10 build — DONE):** built the `postgresql-provisioning` role (Roadmap #10) — declarative DB tenant onboarding on LXC260, replacing the manual `psql` checklist. Scope decided **full** (DB + user + grants + `pg_hba` `hostssl` line + reload); rollout **test-tenant-first**. Role uses `community.postgresql` modules (`postgresql_db`/`_user`/`_privs` ×3 (db-grant, schema revoke-from-PUBLIC, schema grant-to-user)/`_pg_hba`) in a `become_user: postgres` block (peer auth, no password); `notify` reload handler on the versioned unit; `postgres_tenants: []` + `postgres_version: 15` defaults. New `vault_test_dbpass` (via `encrypt_string`), `host_vars/lxc260.yml`, playbook `hosts: database`. **Two real bugs caught in the dry-run, both fixed:** (1) `become_user: postgres` failed the unprivileged-become temp-file handoff (`chmod: invalid mode 'A+user...'`) — root cause **verified** `setfacl` missing → added `acl` to the prereq apt task; (2) the failing task **dumped the password** because `no_log` was only on the user task while the loop `item` carried the secret through every task → restructured: passwords moved to a separate `postgres_tenant_passwords` dict keyed by user, out of the loop item, read only by the `no_log` user task (leaked test password rotated). Real run `failed=0` (8 changed), 2nd run `changed=0` (idempotent), state verified (db + role + `hostssl` line present). Test tenant then **torn down** (`state: absent` ×3 + reload, verified gone); `host_vars` committed as `postgres_tenants: []` with a commented onboarding example; `vault_test_dbpass` removed. Docs: lxc260 + postgresql-platform service doc + `ansible.md` (groups/playbooks/roles) + devops-til. **Next: Roadmap Item #11 — PostgreSQL backup playbook (`pg_dump` on LXC260, verify output, store locally).**

- **Session 2026-06-11b (tooling/meta — open TODOs):** discussed aider + local model workflow as Claude Code fallback. Decisions and open items:
  - **aider config updated** (`~/.aider.conf.yml`): `map-tokens: 4096`, `map-refresh: auto`, `auto-commits: false`, all `attribute-*: false` — no AI attribution in commits, no auto-commits, larger repo-map.
  - **Default model switched to Sonnet** — biggest token-saving lever (~5× cheaper than Opus, full agentic capability retained).
  - **aider role clarified:** Spare Tire only (zero Anthropic tokens). File-level coding, manually driven. No agentik, no auto-doc, hooks off — use only when Anthropic limit is fully exhausted.
  - **Open TODO A — Bash Shell-Out skill (quick win):** build a skill/pattern where Sonnet orchestrates and shells out to `aider --message` for output-heavy boilerplate tasks (5+ similar files). Low effort, no new infra.
  - **Open TODO B — MCP Server wrapping Ollama (Lernprojekt):** ~50 lines Python; exposes `ollama_generate` as a Claude Code tool; enables per-task local-model routing from within Claude Code. Learning payoff: MCP internals, tool-use mechanics. Decision pending — ask at next session start.
  - **Next Ansible task unchanged: Roadmap Item #11** — PostgreSQL backup playbook (`pg_dump` on LXC260, verify output, store locally).

- **Session 2026-06-11 (Item #9 build — DONE):** built the Docker update workflow per the locked 2026-06-09b design. New `docker` group (6 nodes) in `hosts.yml` + `.example`; `compose_projects` list var in 5 new `host_vars/` files + appended to `vm100.yml` (2 stacks); role `docker-compose-update` (`defaults` `compose_projects: []` + `docker_compose_v2` loop with `loop_control: label`); playbook `docker-compose-update.yml` (`hosts: docker`, `serial: 1`, `become: true`). Verified end-to-end: syntax ✓, group/var resolution ✓, real run `failed=0` on all 6, idempotency `changed=0` on rerun, 0 unhealthy containers. Discovery confirmed `become` is mandatory (ansible user not in `docker` group). Docs: 6 node-doc CM sections + `ansible.md` (3 tables) + changelog + roadmap #9 ✅. **Open `--check` caveat:** `docker_compose_v2` in check mode reports `changed` for every stack (can't inspect/pull) — same limitation class as the chrony install→service case; trust the real-run idempotency, not `--check`.
