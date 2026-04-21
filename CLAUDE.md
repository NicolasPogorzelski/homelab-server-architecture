# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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

## Platform Changelog

Significant platform changes, in reverse chronological order. Detailed ACL changes are in `docs/platform/tailscale-acl.md#changelog`.

| Date | Change |
|---|---|
| 2026-04-21 | `chore/repo-review`: SnapRAID runbooks added; Jellyfin + ABS service docs created; KE-4/KE-5 documented; onboarding examples, cross-links, and naming inconsistencies resolved |
| 2026-04-10 | LXC211 Paperless-ngx fully onboarded: `tag:tier1`, Tailscale Serve HTTPS, PostgreSQL on CT260, E2E verified |
| 2026-03-25 | LXC230 OpenWebUI fully onboarded: `tag:ai-stack`, Tailscale Serve HTTPS, PostgreSQL on CT260, Ollama backends (VM100 + Gaming PC), E2E verified |
| 2026-03-20 | LXC260 PostgreSQL platform service added: `tag:database`, centralized DB for all future service consumers |
| 2026-03-09 | `tag:monitoring` formalized in ACL; Rule 1b (monitoring scrape on port 9100) added following container-restart incident (DD#11) |
| 2026-03-04 | LXC250 DevOps workstation added: `tag:admin`, Git + Ansible + IaC, SSH-only (no user-facing services) |

## Adding a New Service

1. Create `docs/services/<service>.md` with an `## Access Model` section referencing `docs/platform/tailscale-acl.md`
2. Create `docs/nodes/<node>.md` with a `## Failure Impact` section
3. Add the node's Tailscale tag to `docs/platform/tailscale-acl.md` (tier model, tag ownership, ACL rules, access matrix, changelog)
4. If Docker-based: add `docker/<service>/docker-compose.yml` and `docker/<service>/.env.example`; use pinned version tags (not `:latest`)
5. Run `./scripts/validate-repo.sh` and fix all errors
