# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Current Work in Progress

- **Branch:** `main`. Ansible track complete (items #1–#13). **Next learning track: Terraform.**
- **Status (2026-07-09):** the learning track is paused. Two independent hardware faults are open
  on the platform and the fleet is running on a disk with 7680 unreadable sectors. Starting
  Terraform on top of this is the wrong order.
- **Two hardware faults, neither fixed:**
  - **KE-13** — aux-disk (the aux disk) is a real media failure, back in service under protest until
    the replacement arrives (~6 weeks from 2026-07-09). Still degrading: `Reported_Uncorrect` 18 → 21
    since the incident. Carries five LXC data-roots and vm100's a few hundred GB `scsi1` disk. No off-site copy.
  - **KE-14** — the boot SSD's I/O errors are **transport faults at the SAS2008 HBA, not media**.
    Media and firmware causes are excluded; the 12 V-rail hypothesis is unverified and needs a
    multimeter, not a shell. `sdc` carries every VM and LXC root disk.
- **Standing hold:** do not run `docker-compose-update` against the fleet while aux-disk is in
  service — it writes gigabytes of new image layers onto the failing disk.
- **Host changes are deferred by decision.** This blocks SMART monitoring (readable only on the
  host), the unapplied `homelab_schedule` role, and the `is_mountpoint 1` storage fix.
- **Next session to-do, in this order:**
  1. Decide the SMART-monitoring path — it requires making the Proxmox host an Ansible-managed
     node. Its absence is why KE-13 ran to total failure unnoticed.
  2. Resolve `origin/docs/storage-stack-client-setup` — five commits stranded, never merged, and
     the conflicts in `CLAUDE.md` / `samba.md` / `storage-stack.md` need a content decision.
  3. Off-site backups. Two failing disks, zero external copies.
- **Detailed handover** — the completed roles/playbooks catalog and per-session narratives live in
  [`docs/platform/ansible-progress.md`](docs/platform/ansible-progress.md). Platform changes and
  their verification live in [`docs/platform/changelog.md`](docs/platform/changelog.md). Append new
  session notes there; keep this section short.

- **Ansible Learning Roadmap (in order):**
  1. ~~OS updates playbook~~ ✅
  2. ~~Bootstrap playbook~~ ✅
  3. ~~First role — node_exporter~~ ✅
  4. ~~Jinja2 templates — prometheus-config role~~ ✅
  5. ~~Handlers~~ ✅
  6. ~~Ansible Vault~~ ✅
  7. ~~SSH hardening role — `PasswordAuthentication no`, `PermitRootLogin no`, sshd handler; adopt `--check --diff` as standard dry-run habit from here on~~ ✅
  8. ~~New node onboarding — `ansible/playbooks/onboarding.yml`: 3 plays (bootstrap as root → ssh-hardening → node_exporter); structure complete, real-node test skipped (no available fresh LXC)~~ ✅
  9. ~~Docker update workflow — pull new images, restart compose stacks via Ansible~~ ✅ (2026-06-11, `docker_compose_update` role)
  10. ~~PostgreSQL provisioning role — create DB + user for new services on LXC260 (replaces manual `psql`)~~ ✅ (2026-06-11, `postgresql_provisioning` role)
  11. ~~PostgreSQL backup playbook — `pg_dump` on LXC260, verify output, store locally~~ ✅ (2026-06-12, `postgresql_backup` role)
  12. ~~Fleet health check playbook — query all nodes, output status overview~~ ✅ (2026-06-12, `fleet-health-check.yml`)
  13. ~~CI/CD + ansible-lint (lightweight) — GitHub Actions: `ansible-lint` on push, `--check` against inventory on PR. Keep minimal — no elaborate matrix or multi-stage pipeline.~~ ✅ (2026-06-12, `.github/workflows/ansible-lint.yml`)
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

OS context: Proxmox host + Debian 12 LXCs. Daily driver is admin workstation (Fedora/rpm-ostree-based).
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

This script enforces 15 checks and is also run by CI on every push/PR to `main`. Fix all errors before merging. The checks catch: empty markdown files, broken internal links, committed `.env` files, missing required doc sections, unsanitized Tailscale IPs / LAN IPs / tailnet IDs, private keys, missing `.env.example` files, files outside the allowed directory structure, duplicate markdown headings, and leftover git merge conflict markers.

## Documentation Audit Rule

Before every commit that touches `docs/` or `ansible/`:

1. Run `./scripts/validate-repo.sh` and fix all errors before staging.
2. Audit all docs touched in this session for content completeness:
   - Required sections present? (`## Access Model`, `## Failure Impact`, `## Configuration Management`)
   - Cross-links to related docs present and correct?
   - Platform Changelog in `docs/platform/changelog.md` updated with today's change?
3. Show audit results to the user before committing — one line per file checked.

This rule applies even if `validate-repo.sh` passes. Structural checks (script) and content checks (this rule) are complementary, not redundant.

## Claude Code Hooks

Project-local hooks are configured in `.claude/settings.local.json` (gitignored, environment-specific paths).
Sanitized reference config: `snippets/claude/hooks-reference.json`.
Reproduction on a new machine: see the `dotfiles` repo.

| Hook | Event | Purpose |
|---|---|---|
| SessionStart | Session opens | Injects current branch + last 5 commits into context |
| PreToolUse (`git commit *`) | Before every commit | Runs `validate-repo.sh`, blocks commit on failure |
| Stop | Session ends | Mandatory `devops-til` update reminder |

Global hooks (e.g. 15-minute learning rule) live in `~/.claude/settings.json` — versioned in the `dotfiles` repo.

## Repository Structure

This is a **documentation and configuration repository** — no application code, no build system, no tests. The content is:

- `docs/` — Architecture, design decisions, node docs, service docs, platform docs
- `docker/` — Docker Compose stacks and `.env.example` files, one directory per service
- `runbooks/` — Operational procedures (must follow the runbook contract)
- `snippets/` — Reference configs, deployment source files, and helper scripts (sanitized): `postgres/` (pg-backup.sh), `scripts/` (utility + maintenance scripts), `storage/` (VM102 Samba config), `systemd/` (unit templates), `ollama/` (model configs), `claude/` (hooks reference)
- `scripts/` — Repo tooling and Proxmox host scripts: `validate-repo.sh` (15-check repo validator), `commit-msg-lint.sh` (git hook, conventional commits), `homelab-setwake.sh` (RTC wakeup scheduling — deployed to host `/usr/local/sbin/`), `homelab-shutdown.sh` (scheduled shutdown — deployed to host `/usr/local/sbin/`)
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
- Disk labels and device names must use generic identifiers (e.g. `disk01`–`diskN`, `aux-disk`) — never real labels that reveal size or purpose
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
- **journald persistence on vm100/vm102 — the previously recorded gap does not exist
  (verified 2026-07-10, as root):** both nodes have `/var/log/journal/<machine-id>/`. vm100
  retains **86 boots** back to 2025-12-27, vm102 **64 boots** back to 2026-02-14, and the KE-8
  window (2026-06-08/09) holds 16,905 and 7,868 journal lines respectively. `Storage=` is unset,
  so `auto` applies, which is persistent whenever `/var/log/journal` exists. Remaining (minor)
  hardening: pin `Storage=persistent` and an explicit `SystemMaxUse=`, because `auto` makes
  persistence a property of a directory that happens to exist rather than of the config, and
  it degrades silently to RAM-only if that directory is ever removed.
- **unattended-upgrades active on vm100 (uncontrolled change):** installs
  packages incl. kernels autonomously, outside the Ansible `apt-upgrade.yml`
  workflow — on a GPU node this risks kernel/NVIDIA-DKMS coupling after the next
  reboot. Decision pending: disable, or restrict to security-only + exclude kernels.
- **LXC220 (Calibre-Web) tagged `tag:tier1`, not `tag:tier2` (rationale being reconfirmed):**
  application service tiering exception, confirmed intentional 2026-07-08. The
  `calibre-importer` role's auto-import mechanism has no verified dependency on
  tier1 access (SMB-only; tier1 and tier2 grant port 445 identically). Untrusted
  devices don't need Calibre-Web access, so no functional gap results. See the
  Tier Model exception note in `docs/platform/tailscale-acl.md`.
- **MergerFS pool close to full on vm102 (by design):** the media archive is meant
  to fill; read-only consumers (Jellyfin/ABS/Calibre) are unaffected, but write
  consumers (Nextcloud/Paperless/Vaultwarden/Postgres-backups) will eventually
  hit `ENOSPC` — capacity expansion is the lever, not deletion. The `<15% free`
  disk alert on archive disks is largely non-actionable (alert tiering by role pending).

- **LXC250 SSH reachability after reboot:** sshd binds only to the Tailscale IP
  (`ListenAddress` in sshd_config). SSH is unreachable for ~30–60 s after boot until
  Tailscale connects. Use `pct exec 250 -- bash` from the Proxmox host as immediate
  fallback, or wait. This is intentional hardening, not a bug.
- **LXC260 boot dependency on SMB mount:** `mp1` binds `/mnt/smb/postgres-backups` into
  the container. After a hard shutdown, LXC260 may fail to start with pre-start hook
  exit 19 (`ENODEV`) if VM102/storage is still booting. Fix: wait for VM102, verify
  `ls /mnt/smb/postgres-backups` on the Proxmox host, then `pct start 260` manually.
- **`homelab_schedule` role not yet applied to live host (2026-06-17):** role deploys
  `homelab-setwake.sh` + `homelab-shutdown.sh` + `/etc/cron.d/homelab-schedule` via Ansible.
  Scripts and cron file currently managed manually. Run `--check --diff` first, then apply.
- **`scan-paperless-inbox.sh` on LXC210 not Ansible-managed:** script deployed manually to
  `/usr/local/sbin/`, scheduled via root crontab. Source: `snippets/scripts/scan-paperless-inbox.sh`.
  No role exists — will be lost on LXC210 rebuild without manual re-deploy.
- **`jellyfin-cuda-watchdog.sh` on VM100 not Ansible-managed:** watchdog polls `nvidia-smi` every
  30 min and auto-restarts Jellyfin on CUDA loss. Deployed manually to `/usr/local/sbin/` via root
  crontab. Source: `snippets/scripts/jellyfin-cuda-watchdog.sh`. Will be lost on VM100 rebuild.
- **Jellyfin CUDA access loss intermittent (KE-10):** hardware transcoding stops randomly; root
  cause unconfirmed (NVML connection goes stale). Workaround: `docker restart jellyfin`. Watchdog
  automates this but does not fix the root cause. See `docs/platform/known-errors.md#ke-10`.
- **SnapRAID cron on VM102 not Ansible-managed:** `/etc/cron.d/snapraid` (sync 23:00, scrub 20:00
  on 1st) managed manually. Source: `snippets/storage/snapraid-maintenance.sh`. No Ansible role —
  requires manual re-deploy after VM102 rebuild.
- **postgres_exporter on LXC260 not Ansible-managed (binds `*:9187`, LAN-exposed):** unlike
  `node_exporter`, no role deploys or configures `postgres_exporter` — it was installed manually
  (2026-04-22) and its systemd unit's `ExecStart` has no `--web.listen-address`, so it binds all
  interfaces instead of the Tailscale IP only. Fix requires a systemd override (must restate the
  full `ExecStart=` — overrides can't append args to an existing line) plus deciding whether to
  adopt the exporter's full lifecycle into Ansible or just this one flag; deferred as its own
  design task rather than bolted onto an unrelated audit pass.
- **Legacy SSH keys on VM102 (`storage` user):** `root@server` and `admin-laptop` keys remain
  in `/home/storage/.ssh/authorized_keys`. Flagged for cleanup; no Ansible task to remove stale
  keys exists yet. See `docs/nodes/vm102.md` Configuration Management section.
- **Calibre library on CIFS — SQLite workaround in place, no durable fix:** `metadata.db` cannot
  safely live on CIFS (byte-range locking). Workaround: local-copy + atomic swap during import
  (see `calibre_importer` role). Moving library to local block storage is the durable fix but
  deferred (no extra volume available). See `docs/decisions/calibre-cifs-sqlite-import.md`.
- **LXC220 rw library mount is DOWN, and has been since 2026-06-08 (KE-15, active):** not the
  transient boot-race this entry used to describe — a month-long steady state. The host's
  `/mnt/smb/books-rw` is unmounted, so the `mp2` bind exposes the empty host-root-owned
  directory beneath it on `pve-root`; container root (unprivileged, host uid `65534`) cannot
  write there, and `calibre-import.service` has failed every 2 minutes ever since. Fix:
  `mount /mnt/smb/books-rw` on the Proxmox host + `pct reboot 220`. Durable fix (automount +
  `x-systemd.mount-timeout`) still not applied. The role's and script's `mountpoint -q` guards
  were blind to this by construction — they tested that *a* mount existed, not *which* — and
  were replaced with an `findmnt -no FSTYPE` == `cifs` check on 2026-07-10. See
  `docs/platform/known-errors.md#ke-15`.

- **Alerting on failed systemd units (KE-15 gap — REMEDIATED 2026-07-10):** previously a unit in
  `failed` state matched no alert category (`NodeDown`, disk fill, and blackbox HTTP probes cover
  none of it), which is why `calibre-import.service` failed ~20,000 times over a month behind a
  green dashboard. Now `node_exporter` runs `--collector.systemd` with `.mount` units kept in
  scope (the stock exclude drops them, and both mount faults found that day were `.mount` units),
  and the `SystemdUnitFailed` rule alerts on `node_systemd_unit_state{state="failed"} == 1` after
  `for: 15m`. The rule carries no exception list on purpose: units that can never succeed on a
  node are masked or removed at the source by the `systemd_hygiene` role. Caveat: lxc200 is not
  covered (see below).

- **`ansible-lint` cannot see broken handler wiring:** handler names are resolved at *notify*
  time, not parse time, so a `notify:` pointing at a non-existent handler passes `--syntax-check`
  and every lint profile, and only errors at runtime when a notifying task actually reports
  `changed`. A `--fix` run that renames handlers will not update the `notify:` strings pointing
  at them (this happened in `355b449`, fixed 2026-07-10). After any `ansible-lint --fix`, diff
  `handlers/main.yml` names against `notify:` values by hand.
- **PostgreSQL backups have not run since 2026-06-14 (26 days as of 2026-07-10, ACTIVE):**
  `pg_backup_last_success_timestamp` = `1781406008`. This entry previously claimed a daily
  `pg_dump` runs and only lacks restore testing — wrong on the more important half. The
  `PostgreSQLBackupStale` rule fires correctly and reaches Discord, so detection works;
  the backup itself does not. Verified: the CIFS target `/mnt/backups` **is** mounted and
  `/usr/local/sbin/pg-backup.sh` is present. Unverified: whether the `postgres`-user crontab
  entry exists, whether the target is writable by `postgres`, and the script's failure output.
  Restore testing remains absent on top of that — there is still no runbook and no periodic
  validation that a restore succeeds.

- **lxc200 monitors the fleet but not itself:** `node-exporter.yml` runs against `all:!lxc200`,
  because lxc200's node_exporter is a Docker container that cannot see the host's systemd units.
  The new `SystemdUnitFailed` rule therefore covers eight of nine nodes, and the monitoring node
  is the blind one. Needs its own design decision (privileged container with `/run/systemd`
  bind-mounted, or a native node_exporter alongside the container).
- **Off-site backups not implemented:** current backups are local only (SMB on VM102). No
  protection against full-site loss or ransomware. Critical subsets (Vaultwarden export,
  Nextcloud DB, Paperless documents) have no off-site copy.
- **SMART monitoring not deployed (highest-leverage gap):** no `smartctl_exporter` or
  node-exporter textfile collector for disk health. Disk failure detection relies on SnapRAID
  alerts, not SMART. **This gap is why KE-13 ran to total failure unnoticed, and why the disk was
  returned to service without anyone seeing it still degrading.** Note: all nine disks are attached
  to the **Proxmox host**; VM102 reaches six of them via `by-id` passthrough and sees only
  virtio-SCSI devices, so SMART is readable *only on the host* — the previous wording here named
  VM102 as the target node and was wrong. Deploying this requires the host to become an
  Ansible-managed node, the same prerequisite `homelab_schedule` is waiting on.
  Listed as planned enhancement in `docs/platform/operations.md`.
- **LXC250 (control node) tracks `main` only — verify before every live run:** playbooks execute
  from the working tree, not from a commit, so a node on a feature branch or mid-merge silently runs
  code matching no commit. Update with `git pull --ff-only`; do feature work on a workstation. Before
  a run that changes live state: `git status --short --branch` must show a clean `main`, and
  `grep -rlE "^(<<<<<<<|=======|>>>>>>>)" ansible/` must print nothing. `validate-repo.sh` Check 15
  only catches markers that reach a commit. (Found mid-merge on 2026-07-09; resolved.)
- **VM100 sshd binds `0.0.0.0:22` (LAN-exposed), violating the platform binding rule:** unlike
  lxc250, which pins `ListenAddress` to its Tailscale IP. Password auth is off since 2026-07-09,
  so the acute risk is closed, but the bind is wrong and contradicts vm100.md's own "LAN exposure
  limited to 8096/13378 only". Fixing it couples sshd startup to Tailscale being up — the
  KE-9/KE-12 boot-race class. Needs its own design decision, including whether `ssh_hardening`
  should own `ListenAddress`. Do not bolt this onto an unrelated pass.
- **KE-14 — boot-time I/O errors on the boot SSD, root cause unconfirmed:** intermittent
  `DID_SOFT_ERROR` bursts against the boot SSD (LSI SAS2008 HBA) during the boot window only.
  Media and HBA-firmware causes are excluded; leading hypothesis is a sagging 12 V rail.
  Requires physical verification (multimeter, cable reseat, HBA temperature, PSU age).
  `sdc` carries every VM and LXC root disk, so an `EIO` into the thin pool during guest start
  could corrupt a guest filesystem. See `docs/platform/known-errors.md#ke-14`.
- **aux-disk is back in service with 7680 unreadable sectors (KE-13), replacement ~6 weeks out:**
  it carries the Docker data-roots of LXC200/211/220/230/260 **and VM100's a few hundred GB `scsi1` disk**
  (allocated). `Reported_Uncorrect` rose 18 → 21 since the 2026-06-25 incident — it is
  still degrading in service. Nothing on `/mnt/aux-disk` has an off-site copy.
- **Standing hold on `docker-compose-update` (until aux-disk is replaced):** the role pulls new
  images, writing gigabytes of fresh blocks onto that disk. The repo-side image pins and the
  role's compose-file-sync fix can wait for the replacement.
- **`appdata_aux-disk` storage lacks `is_mountpoint 1` (host change, deferred):** if aux-disk fails to
  mount, Proxmox treats the storage as active and writes into the empty mountpoint on `pve-root`,
  filling the boot SSD — the KE-7 failure class. `mkdir 0` does not prevent this.

## Platform Changelog

The full platform changelog lives in [`docs/platform/changelog.md`](docs/platform/changelog.md) (reverse chronological), kept out of this file so the always-loaded instruction context stays small. Detailed ACL changes are in `docs/platform/tailscale-acl.md#changelog`. **When recording a new platform change, append it there, not here.**

## Adding a New Service

1. Before implementation: link official upstream docs, identify relevant sections, wait for confirmation
2. Create `docs/services/<service>.md` with an `## Access Model` section referencing `docs/platform/tailscale-acl.md`
3. Create `docs/nodes/<node>.md` with a `## Failure Impact` section
4. Add the node's Tailscale tag to `docs/platform/tailscale-acl.md` (tier model, tag ownership, ACL rules, access matrix, changelog)
5. If Docker-based: add `docker/<service>/docker-compose.yml` and `docker/<service>/.env.example`; use pinned version tags (not `:latest`)
6. If Docker-based: configure Docker engine data root on aux-disk from the start — set `data-root` in `/etc/docker/daemon.json` and `root` in `/etc/containerd/config.toml` to point to a subdirectory of the node's aux-disk mount (e.g. `/var/lib/<service>/containerd` and `/var/lib/<service>/docker-data`); prevents SSD thin-pool pressure from image accumulation
7. Run `./scripts/validate-repo.sh` and fix all errors
