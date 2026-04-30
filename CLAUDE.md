# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Current Work in Progress

- **Ansible:** installation complete (`ansible-core 2.19.9` via `pipx` on LXC250)
- **Next session:** create `ansible/` directory structure, `ansible.cfg`, `inventory/hosts.yml`,
  and first playbook to automate node_exporter deployment on VM102 (replicating
  what was done manually on 2026-04-23)

## Working Context (Learning Mode)

This repo is a learning vehicle and portfolio piece for a DevOps career transition.
When working on tasks here:

- Explain every CLI flag and every config value — no copy-paste answers.
- For new tools or configs: link to official documentation first, identify
  relevant sections, then implement.
- Root cause before fix: symptom → verification command → diagnosis → fix.
- Small steps, verify before next step.
- When unsure, say so. Don't hallucinate flags, paths, or behavior.

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

## Repository Structure

This is a **documentation and configuration repository** — no application code, no build system, no tests. The content is:

- `docs/` — Architecture, design decisions, node docs, service docs, platform docs
- `docker/` — Docker Compose stacks and `.env.example` files, one directory per service
- `runbooks/` — Operational procedures (must follow the runbook contract)
- `snippets/` — Reference configs and helper scripts (sanitized)
- `scripts/` — Repo tooling (`validate-repo.sh`)

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

## Platform Changelog

Significant platform changes, in reverse chronological order. Detailed ACL changes are in `docs/platform/tailscale-acl.md#changelog`.

| Date | Change |
|---|---|
| 2026-04-30 | Docker engine data root migrated to Aux1TB on LXC211, LXC230, LXC200, LXC220: containerd + Docker data moved from local-lvm root disks to existing Aux1TB mounts; LXC220 received new `mp1` (`/mnt/aux1TB/calibreweb`); SSD thin-pool reduced from 88% → 62% (24.9 GB freed after fstrim) |
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
6. If Docker-based: configure Docker engine data root on Aux1TB from the start — set `data-root` in `/etc/docker/daemon.json` and `root` in `/etc/containerd/config.toml` to point to a subdirectory of the node's Aux1TB mount (e.g. `/var/lib/<service>/containerd` and `/var/lib/<service>/docker-data`); prevents SSD thin-pool pressure from image accumulation
7. Run `./scripts/validate-repo.sh` and fix all errors
