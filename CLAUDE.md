# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Current Status

The Ansible learning track (roadmap items #1-#13) is complete and merged to `main`: everything
guest-side is Ansible-managed and every scheduled job is a systemd timer. The next learning track is
Terraform. The completed role/playbook catalog and per-session narratives live in
[`docs/platform/ansible-progress.md`](docs/platform/ansible-progress.md); platform changes and their
verification live in [`docs/platform/changelog.md`](docs/platform/changelog.md). Record new session
notes there and keep this section short.

**Open operational items** (full detail in [`docs/platform/known-errors.md`](docs/platform/known-errors.md); ordering and dependencies in [`docs/platform/remediation-plan.md`](docs/platform/remediation-plan.md); the same items read as security controls in [`docs/platform/security-controls.md`](docs/platform/security-controls.md), with data classification and recovery objectives in [`docs/platform/data-classification.md`](docs/platform/data-classification.md)):

- **KE-13 - aux-disk media failure.** The auxiliary disk is back in service under protest pending a
  replacement. It carries five LXC data-roots and VM100's secondary disk, with no off-site copy.
  Standing hold: do not run `docker-compose-update` against the fleet while this disk is in service
  - it writes gigabytes of new image layers onto a failing disk. **Correction (measured
  2026-07-28):** the earlier "still degrades slowly" no longer holds. `Reported_Uncorrect` rose
  18 -> 21 between 2026-06-25 and 2026-07-09 and has been static at 21 since (re-measured
  2026-08-13), with `Current_Pending_Sector` static at 7680 - thirty-five further days in service
  with no new uncorrectable error. Static is not safe (those 7680 sectors still hold unreadable data, and
  `smartctl -H PASSED` is meaningless here: `Current_Pending_Sector` normalises to 054 against
  threshold 000 and can never trip the self-assessment), but the failure is not accelerating, so
  the replacement is a planned task rather than an emergency.
- **KE-18 - Tailscale readiness races (class entry, added 2026-07-28).** Four instances, all fixed:
  lxc260 PostgreSQL (KE-9), host `pveproxy` (KE-12), host `node_exporter` and lxc210
  `tailscale-cert-refresh` (both 2026-07-28). The host `node_exporter` case was a **regression from
  `54402ed`**, which moved the bind to the Tailscale IP on 2026-07-14 and thereby put the unit into
  this class; it had failed at every boot since, and the failure concealed itself because a dead
  host exporter is precisely what stops the host from reporting. **All four cold-boot confirmed
  2026-08-13**, including the lxc210 query-time instance, whose fix only a boot could exercise:
  its `Persistent=true` catch-up fired 82 s into the boot window and the poll waited 11 s for
  `Self.DNSName`. The fifth instance - lxc250's hand-written sshd drop-in, which
  retried rather than waited - is owned by the `tailscale_boot_gate` role since
  2026-08-20 and cold-boot confirmed the same day (gate returned after 2 s,
  `NRestarts=0`). Note what the hand-written version got right and a naive
  replacement would have lost: Debian's `ssh.service` sets
  `RestartPreventExitStatus=255`, and sshd exits 255 on a failed bind, so the retry
  only worked because the drop-in cleared that list. **That reboot also found nine
  more instances.** The `node_exporter` on every guest binds the Tailscale address
  with ordering and a retry but no gate, and all nine failed once at that boot with
  `EADDRNOTAVAIL` (`NRestarts=1`); the hypervisor read 0, having carried a
  hand-written gate since 2026-07-28. Nothing reported it: the retry makes the end
  state correct, `SystemdUnitFailed` has `for: 15m` and cannot see a 15-second
  failure, and the exporter that would report the fault is the one that is down.
  The gate is in the role's unit template since 2026-08-20 and **fleet cold-boot
  confirmed 2026-08-21**: nine of nine `NRestarts=0`, no failed unit, and eight of
  the nine gates measurably waited (2-12 s; only vm100 already held its address).
  Read the two together or not at all - `NRestarts=0` is also what a node that never
  rebooted reports, so the proof is each unit's `ActiveEnterTimestamp` falling after
  that node's `uptime -s`. Every known instance in this class is now proven by a boot
  rather than a restart.
- **KE-6 recurrence on lxc220 - RESOLVED 2026-07-28.** The node had been running a second,
  hand-written `tailscaled-userspace.service` alongside the packaged unit, so two daemons started
  every boot and its `node_exporter` had, as far as can be established, never been scraped. KE-6 had
  been closed after fixing lxc240 without sweeping the fleet. **Take the general lesson: when
  closing a configuration error, sweep the other nodes and record that you did.**
- **KE-14 - boot SSD I/O errors.** Diagnosed to the transport layer at the SAS2008 HBA, not the
  media; the leading (unverified) hypothesis is a sagging 12 V rail, which needs physical
  verification. The boot SSD carries every VM and LXC root disk. Fired again 2026-08-13
  (`cmd_age=29s`, boot + 3 min, preceding boot clean) - live, and no verification step performed.
  **Never identify this disk by its kernel letter:** the docs said `sdc` for a month and it
  enumerated as `sda` on 2026-08-13. Use the SCSI address `9:0:0:0` or `by-id`.
- **KE-15 - RESOLVED 2026-07-14, closed 2026-08-13.** The host's `/mnt/smb/books-rw` fstab entry
  lacked `x-systemd.automount`, so the mount was attempted once at boot - against a VM the host
  itself had not started yet - failed, and was never retried. Confirmed across a real host power
  cycle: all seven `/mnt/smb` entries resolve to `cifs`, `calibre-import` exits 0.
- **PostgreSQL restore testing - validated and automated 2026-08-13.** The earlier wording here
  ("restores are never validated - no runbook, no periodic check") was wrong on two of three
  counts: `runbooks/database/pg-restore.md` exists and had a recorded pass from 2026-04-04. Now
  a full-cluster restore into a throwaway cluster on port 5433 runs monthly via the
  `postgresql_restore_test` role (`*-*-01 09:00`, `Persistent=true`), asserting dump integrity,
  restore success and non-empty key tables, with `PostgreSQLRestoreTestStale` alerting at 40 days.
  Nothing live is touched. The 09:00 slot is load-bearing: the restored cluster holds ~150 MB
  of thin-pool blocks and a container cannot `fstrim` itself, so it relies on the host's
  `lxc-fstrim.timer` at 10:30 to reclaim them the same morning.
  **Write-time verification closed 2026-08-14.** `pg-backup.sh` now writes to `*.sql.gz.partial`
  and renames only after three checks pass - non-empty, `gzip -t`, and exactly one
  `cluster dump complete` marker - with verification ordered before retention deletion,
  because retention keeps 7 days while the monthly test detects up to 31 days late. Only the
  marker check catches a valid gzip of a half-finished dump, which restores without error into
  empty tables. What it does not prove: durability on vm102 - the read-back comes from the CIFS
  page cache. Still open: no off-site copy.
- **`PostgreSQLBackupStale` cannot see an outage (measured 2026-08-14).** The 25-hour rule is blind
  whenever the host is off, because Prometheus runs on that same host: no scrape, and the timer's
  `Persistent=true` catch-up refreshes the timestamp before Prometheus is back. Measured: a 62-hour
  scrape gap 2026-08-10 21:50 -> 2026-08-13 11:50, no dump written in it, alert empty across the
  range. It means "not more than 25 h of uptime without a backup", not "a backup every day".
  Deliberately not fixed - on a host that powers down nightly by design, an alert for "the host was
  off" is noise. Same class as the host `node_exporter` whose failure concealed itself: **a guard
  that shares a failure domain with what it guards.** Corollary: retention is 7 *days*, not 7 dumps.
- **LXC250 control node sits outside the system it manages (found 2026-07-28).** It holds three
  roles and none is secured: it is the *deployment source* (playbooks read the working tree, not a
  commit), the *only copy* of `~/.vault_pass`, the real `hosts.yml` and the Ansible SSH key (all
  gitignored, no backup, and the container lives on the KE-14 boot SSD), and it appears in **no
  inventory** - so `hosts: all` silently excludes it and it has no `node_exporter`, no `NodeDown`,
  no disk alert on its 8 GB, and neither Ansible-driven nor unattended patching. Found two commits
  behind `origin/main`; a `tailscale-cert.yml` run would have re-deployed the pre-fix
  `tailscale-cert-refresh.sh` over the live KE-18 fix and the symptom would have surfaced ~2 months
  later as an expired certificate. Agreed plan, in order: (1) escrow `~/.vault_pass` +
  `hosts.yml` in Vaultwarden and demote the GitHub key to a read-only deploy key (no repo change,
  irreversible-loss risk, do first); (2) branch `feat/lxc250-ansible-adoption` - add to `lxcs`
  with `prometheus_label: devops`, re-render prometheus config, adopt the hand-written
  `ssh.service.d/override.conf` into a role and convert it to the `wait-for-tailscale-ip.sh` gate
  (it is an unlisted fifth KE-18 instance, currently surviving on a retry loop, not a readiness
  check); (3) branch `feat/control-node-preflight` - `preflight.yml` imported via
  `import_playbook`, asserting a clean `main` in sync with `origin`, plus a drift metric once the
  exporter exists. Rejected on purpose: auto-pull (trades awareness for convenience), ephemeral
  per-run clones (right answer, revisit for Terraform where state raises the stakes), and
  Actions-triggered deploys (needs a self-hosted runner plus fleet secrets in GitHub, and "on
  merge" means nothing on a host that sleeps at night). Measured 2026-08-13, the node was not
  missing an exporter but running a wrong one: a hand-written unit from 2026-04-22 started
  `node_exporter` with no arguments, so it bound `*:9100` (LAN-exposed, the third instance of the
  defect fixed on lxc260 and the host) and was scraped by nobody, while `systemctl is-active`
  said `active` and read as coverage. Step (2) was therefore a replacement, not an addition.
  **Status 2026-08-20:** steps (1) and (2) are done. The account exists, the node is in the real
  inventory as part of `lxcs` and `guests`, the exporter is the role's and binds the Tailscale
  address, Prometheus scrapes it (`node-lxc250-devops`, `up`), and 850 `node_systemd_unit_state`
  series mean `SystemdUnitFailed` finally covers it. The sshd drop-in is adopted into the
  `tailscale_boot_gate` role, pending a cold boot to verify. Step (3), `preflight.yml`, is
  untouched.
- **Nextcloud's MariaDB has no backup, and parity is not backup (found 2026-08-15).** The nightly
  `pg_dumpall` covers lxc260 only; Nextcloud's database runs *inside* lxc210 and no role, script,
  unit or crontab entry dumps it. Its user files live on the archive pool, its database on the
  KE-14 boot SSD - **the two halves of one dataset, on different disks, with different protection,
  and the weaker half is the one that makes the other meaningful.** Losing that SSD leaves every
  file intact and unusable. Same pass found that Vaultwarden, Paperless documents and Nextcloud
  files rely on SnapRAID parity and nothing else: parity protects against *disk* loss, not against
  deletion, corruption or ransomware, because the next `snapraid sync` writes the damage into the
  parity. And parity over a live database is worse than it looks (KE-19, 2026-08-15): `Vaultwarden/db.sqlite3-shm` and `-wal` sat in the array, so parity captured them at a different moment than the main database - an inconsistent set from which a reconstruction can be corrupt. The side files are now excluded; `db.sqlite3` itself deliberately stays in, because imperfect protection beats none until the export exists. Tier 1 #3 was reworded - it had presumed local copies existed to be duplicated off-site.
  **Verified live 2026-08-15** via `pct exec`: empty root crontab, no dump among eleven timers, and
  the only dumps anywhere under `/mnt/smb` are six `pg_dumpall_*` files. The schema is 38.3 MB
  across 179 InnoDB tables - the gap was never a cost problem. `postgresql_backup` was built
  when lxc260 became "the platform database", and nobody checked whether that phrase covered every
  database; Nextcloud's predates the decision and fell outside a category declared complete. The
  `mariadb_backup` role, script and runbook now exist and are live since 2026-08-15 - share
  provisioned on vm102, host fstab entry, `mp1` bind, `pct reboot 210`, playbook applied, first
  verified dump on the share (2.2 MB, one completion marker), metric scraped, `MariaDBBackupStale`
  promoted and inactive. Nextcloud files are still parity-only, and **Vaultwarden still has no
  consistent export** - an SQLite file copied from a live CIFS mount is a gamble on timing, not a
  backup. That is now the last open half of Tier 1 #3 before the off-site question itself.
- **Deferred to the hardware-replacement window:** host-side SMART monitoring (requires making the
  Proxmox host an Ansible node), the unapplied `homelab_schedule` role, the `is_mountpoint 1`
  storage fix, and the storage-migration design discussion.

- **Ansible Learning Roadmap (in order):**
  1. ~~OS updates playbook~~
  2. ~~Bootstrap playbook~~
  3. ~~First role - node_exporter~~
  4. ~~Jinja2 templates - prometheus-config role~~
  5. ~~Handlers~~
  6. ~~Ansible Vault~~
  7. ~~SSH hardening role - `PasswordAuthentication no`, `PermitRootLogin no`, sshd handler; adopt `--check --diff` as standard dry-run habit from here on~~
  8. ~~New node onboarding - `ansible/playbooks/onboarding.yml`: 3 plays (bootstrap as root -> ssh-hardening -> node_exporter); structure complete, real-node test skipped (no available fresh LXC)~~
  9. ~~Docker update workflow - pull new images, restart compose stacks via Ansible~~ (2026-06-11, `docker_compose_update` role)
  10. ~~PostgreSQL provisioning role - create DB + user for new services on LXC260 (replaces manual `psql`)~~ (2026-06-11, `postgresql_provisioning` role)
  11. ~~PostgreSQL backup playbook - `pg_dump` on LXC260, verify output, store locally~~ (2026-06-12, `postgresql_backup` role)
  12. ~~Fleet health check playbook - query all nodes, output status overview~~ (2026-06-12, `fleet-health-check.yml`)
  13. ~~CI/CD + ansible-lint (lightweight) - GitHub Actions: `ansible-lint` on push, `--check` against inventory on PR. Keep minimal - no elaborate matrix or multi-stage pipeline.~~ (2026-06-12, `.github/workflows/ansible-lint.yml`)
  14. ~~Molecule - unit testing for Ansible roles~~ Deferred - out of scope for the current learning arc; revisit after the Terraform and Kubernetes tracks.

  **Note:** LXC provisioning (creating containers) is intentionally excluded - that belongs to Terraform, which follows as the next learning track after Ansible.

**Next learning track (after Ansible):** Terraform - primarily on AWS (free tier) to learn HCL/state/modules on a widely-used provider, plus a thin Proxmox slice for the homelab payoff: `terraform apply` -> LXC exists -> `onboarding.yml` configures it.

**Roadmap after Terraform:** Kubernetes (k3s) basics, then cloud depth and Python. Bash scripting is cross-cutting throughout. Detailed timeline, certifications, and career milestones live in the private global instructions, not in this repo.

**PR Cadence:** Learning-path branches (`feat/ansible-setup`, `feat/terraform-setup`, etc.) are merged to `main` as a whole when the topic is complete - not after individual items. The items within a topic build on each other and form a single coherent arc. Exception: self-contained platform changes unrelated to the learning topic (e.g. runbooks, hotfixes) are split off to their own branch and PRed independently.

## Working Context (Learning Mode)

This repo is a learning vehicle and portfolio piece for a DevOps career transition.
When working on tasks here:

- Explain every CLI flag and every config value - no copy-paste answers.
- **Check every term against the glossary before writing an explanation.** The register lives at
  `~/git/devops-til/glossary.md`. A term that is in it may be used and linked; a term that is not in
  it requires a full explanation on the spot - what it is, where it appears in this setup, why it
  matters - and is then added to the register in the same pass. Abbreviations are the main offender:
  `HA`, `LRM`, `PSI`, `MCE` and `mux` were all used here as if self-evident. This is a mechanical
  gate rather than a matter of judgement, because whether a word is obvious is the reader's call and
  the writer cannot see the gap they leave.
- For new tools or configs: link to official documentation first, identify
  relevant sections, then implement.
- Root cause before fix: symptom -> verification command -> diagnosis -> fix.
- Small steps, verify before next step.
- When unsure, say so. Don't hallucinate flags, paths, or behavior.
- Name the general pattern, not just the fix. Every finding belongs to a class, and this
  platform usually already holds other instances of it - cross-link them. Example: "ordering
  is not readiness" (KE-18) and "free is not deallocated" (thin-pool discard) are the same
  abstraction gap, one layer apart.
- Address wrong assumptions head-on. When a stated assumption is incorrect, say why it is
  intuitive and where exactly it breaks. Quietly answering around it leaves the
  misconception intact and it resurfaces later, usually as an outage.
- Code learning (Bash/Python/YAML): blank-file-first. The first draft is written
  from an empty file without AI or copied snippets - AI is used only to review
  afterwards. The goal is active recall, not recognition; the struggle is the point.

OS context: Proxmox host + Debian 12 LXCs. The admin workstation runs an immutable
Fedora/rpm-ostree-based OS. Commands must be OS-specific - no generic "Linux commands" when
behavior differs.

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

This script enforces 34 checks and is also run by CI on every push/PR to `main`. Fix all errors before merging. The checks catch: empty markdown files, broken internal links, committed `.env` files, missing required doc sections, unsanitized Tailscale IPs / LAN IPs / tailnet IDs, private keys, missing `.env.example` files, files outside the allowed directory structure, duplicate markdown headings, leftover git merge conflict markers, `ansible-lint` findings, tracked `*.local.md` private files, size-encoding disk labels (`auxNtb`), non-ASCII punctuation, bold used as mid-sentence emphasis instead of as a label, German text in repository content, personal media library counts, measured fill levels for the archive pool, unbalanced markdown code fences, counted claims in the README that no longer match the repository, documents that no index links to, backticked repository paths that no longer exist, undocumented Ansible roles, node documents whose Tailscale tag the ACL model does not define, container images without an explicit version tag, secret-looking Ansible variables holding literal values, Enforced control rows that cite no evidence, service documents naming a node that has no node document, and git refs outside the standard namespaces.

**Nothing personal goes into this repository.** It is public and read by recruiters. Infrastructure
gets sanitized by placeholder (addresses, keys, disk labels); facts about the *owner* do not get
sanitized, they get left out. An exact count of films, series or audiobooks proves nothing that
"the library enumerates its full expected contents" does not, and describes what somebody watches,
reads and listens to. Check 22 catches the counts and Check 23 the fill levels; neither catches the
category, so ask before writing any number that describes content rather than infrastructure.

The trap that caught this twice: a text explaining that a value was removed is one more place the
value appears. Describe the shape of what was taken out, never the value itself - "the
percentage-full form and its inverse", not the two figures.

**Check 16 (`ansible-lint`) is a pre-commit net, not a second CI stage.** It runs only when `ansible-lint` is on `PATH` *and* the diff touches `ansible/`; otherwise it prints `SKIP` and passes. Under CI it always skips - `actions/checkout` leaves a clean tree, so there is no diff - because `.github/workflows/ansible-lint.yml` already lints every push. Install the pinned version locally so the check is not silently inert: `pipx install 'ansible-lint==26.6.0'`. A local version other than CI's would gate commits against a different rule set.

## Documentation Audit Rule

Before every commit that touches `docs/` or `ansible/`:

1. Run `./scripts/validate-repo.sh` and fix all errors before staging.
2. Audit all docs touched in this session for content completeness:
   - Required sections present? (`## Access Model`, `## Failure Impact`, `## Configuration Management`)
   - Cross-links to related docs present and correct?
   - Platform Changelog in `docs/platform/changelog.md` updated with today's change?
3. Show audit results to the user before committing - one line per file checked.

This rule applies even if `validate-repo.sh` passes. Structural checks (script) and content checks (this rule) are complementary, not redundant.

## Claude Code Hooks

Project-local hooks are configured in `.claude/settings.local.json` (gitignored, environment-specific paths).
Sanitized reference config: `snippets/claude/hooks-reference.json`.
Reproduction on a new machine: see the `dotfiles` repo.

| Hook | Event | Purpose |
|---|---|---|
| PreToolUse (Bash) | Before any command that commits | `scripts/hooks/pre-commit-guard.sh` - refuses a commit on `main`, and refuses any commit while `validate-repo.sh` reports findings |
| SessionStart | Session opens | Injects current branch + last 5 commits into context |
| Stop | Session ends | `devops-til` update reminder |

**This table states the intent; each machine satisfies it separately.** `.claude/settings.local.json`
is gitignored and carries absolute paths, so it is per-workstation state that no commit can
guarantee. On the admin notebook, checked 2026-08-17, the file held no `hooks` key at all: the
commit gate was absent there and `validate-repo.sh` ran only when it was invoked by hand. What the
other workstation holds was not checked and is not claimed here. Verify per machine with
`jq '.hooks' .claude/settings.local.json` rather than by reading this table - a guard assumed from
a document is the failure this repository keeps finding in its own monitoring, and configuration
that lives outside version control is exactly where it hides.

The guard matches `git ... commit` anywhere in the command string, because commits here are
normally part of a compound command (`git add -A && git commit -F -`) that a `Bash(git commit *)`
prefix rule never sees. It answers `permissionDecision: deny`, which blocks the one call and leaves
the session alive, rather than `continue: false`, which ends the turn.

Global hooks (e.g. 15-minute learning rule) live in `~/.claude/settings.json` - versioned in the `dotfiles` repo.

## Repository Structure

This is a documentation and configuration repository - no application code, no build system, no tests. The content is:

- `docs/` - Architecture, design decisions, node docs, service docs, platform docs
- `docker/` - Docker Compose stacks and `.env.example` files, one directory per service
- `runbooks/` - Operational procedures (must follow the runbook contract)
- `snippets/` - Reference configs, deployment source files, and helper scripts (sanitized): `postgres/` (pg-backup.sh), `scripts/` (utility + maintenance scripts), `storage/` (VM102 Samba config), `systemd/` (unit templates), `ollama/` (model configs), `claude/` (hooks reference)
- `scripts/` - Repo tooling and Proxmox host scripts: `validate-repo.sh` (34-check repo validator), `commit-msg-lint.sh` (git hook, conventional commits), `homelab-setwake.sh` (RTC wakeup scheduling - deployed to host `/usr/local/sbin/`), `homelab-shutdown.sh` (scheduled shutdown - deployed to host `/usr/local/sbin/`)
- `ansible/` - Ansible configuration, inventory, playbooks, roles

Only these top-level directories are allowed (enforced by Check 12), plus the files `README.md`,
`CLAUDE.md`, `LICENSE` and `.gitignore`. `LICENSE` must stay in the root - GitHub's license
detection looks nowhere else. `SECURITY.md` lives in `.github/` instead, which Check 12 skips as a
hidden entry and which GitHub reads just as well.

## Documentation Conventions

**Mandatory sections by doc type** (enforced by validation):

| Doc type | Required section |
|---|---|
| `docs/services/*.md` | `## Access Model` (Zero Trust) |
| `docs/nodes/*.md` | `## Failure Impact` |
| `runbooks/**/*.md` (non-README) | `Precondition`, `Verification`, `Failure`, `Rollback` |

**Writing style** (partly enforced by validation):

- **English, always.** Documentation, code comments, commit messages, branch names, PR titles and
  PR descriptions. This holds regardless of the language the work is being discussed in - a German
  conversation about a change does not produce a German commit or a German pull request. The
  repository is public and read by people who do not speak German.
- ASCII punctuation only, enforced by Check 19. No em or en dashes, curly quotes, ellipsis
  characters, arrows, multiplication signs or emoji. Write `-`, `"`, `...`, `->`, `x`. Exceptions:
  box-drawing characters inside ASCII diagrams, and the section sign when citing a document section.
- Bold marks a label at the start of a line or list item, as in `- **Precondition:** ...`.
  Not a clause inside a running sentence.
- Vary the phrasing. A construction that turns up in every entry stops being writing and becomes a
  template.
- Keep it short. A runbook is read during an incident, not at a desk. Length is a cost.

**Who drafts what:**

- `README.md`, the ADRs under `docs/decisions/` and `docs/platform/security-controls.md` are
  drafted blank-file-first, the same rule this file already sets for code. Review afterwards for
  gaps, contradictions and missing verification.
- Operational logs (`changelog.md`, `known-errors.md`, `ansible-progress.md`) and runbook mechanics
  can be drafted directly, then reviewed. Nothing is merged that cannot be defended in a
  conversation about it.

**Sanitization rules** (enforced by validation):

- Tailscale IPs must use placeholder `<tailscale-ip-nodename>`, never bare `100.x.y.z`
- Tailnet IDs must use placeholder `<tailnet-id>`, never bare `*.ts.net`
- Disk labels and device names must use generic identifiers - never real labels that reveal size
  or purpose. The auxiliary disks need two distinct names, because there are two of them and one
  placeholder for both caused a documented disk to be described on the wrong node:
  - `disk01`-`diskN` - SnapRAID data disks on vm102
  - `aux-pool` (`/mnt/aux-pool`) - the auxiliary disk inside vm102's MergerFS/SnapRAID pool, healthy
  - `aux-disk` (`/mnt/aux-disk`, storage `appdata_aux-disk`) - the auxiliary disk on the Proxmox
    host carrying five LXC Docker data-roots and vm100's second disk; this is the failing KE-13
    drive. When a document says "the aux disk" without qualification it means this one.
- Never commit `.env` files; only `.env.example` files belong in the repo
- Each `docker/` subdirectory with a `docker-compose.yml` must have a `.env.example`

## Architecture

Single-host Proxmox platform. No HA - recovery-oriented design.

**Compute layer:** VM100 (Docker, GPU/NVIDIA) runs media services (Jellyfin, Audiobookshelf) and inference backends (Ollama).

**Storage layer:** VM102 (MergerFS + SnapRAID + Samba). Services access storage over SMB via Tailscale, not LAN.

**Service LXCs** (all Docker-in-LXC unless noted):
- LXC200 - Monitoring (Prometheus + Grafana)
- LXC210 - Nextcloud (native stack: Apache + PHP + MariaDB + Redis)
- LXC211 - Paperless-ngx
- LXC220 - Calibre-Web
- LXC230 - OpenWebUI (AI stack entrypoint)
- LXC240 - Vaultwarden (secrets tier)
- LXC250 - DevOps workstation (Git, Ansible, IaC - no user-facing services)
- LXC260 - PostgreSQL (centralized platform database; all services that need a DB use this)

**Access model:** Zero Trust via Tailscale. No public ingress, no port-forwarding, LAN is untrusted. Nodes are grouped into tags (`tag:tier0`, `tag:tier1`, `tag:tier2`, `tag:monitoring`, `tag:database`, `tag:ai-stack`, etc.) with explicit ACL rules. The ACL policy lives in the Tailscale admin console; `docs/platform/tailscale-acl.md` mirrors the intended model.

**Binding rule:** Services bind to the Tailscale IP directly, or to loopback and proxied via `tailscale serve`. Never to LAN interfaces.

## Known Technical Debt & Gotchas

Do not flag these as new issues - they are documented tradeoffs or known quirks:

- **LXC220 (Calibre-Web):** UID mapping requires `chown 100000:100000` on mounted storage.
- **LXC240 (Vaultwarden):** SQLite on CIFS is a known limitation, documented as tech debt.
- **Grafana admin password:** only read on first container start. Reset via
  `grafana-cli admin reset-admin-password`.
- **Tailscale Serve HTTPS/HTTP mismatch:** fix with `tailscale serve off` + reconfigure.
- **`network_mode: host` + Docker:** no Docker DNS resolution, use `127.0.0.1`
  instead of container names.
- **VM100 Jellyfin CUDA:** requires `pid: "host"` in docker-compose for
  NVIDIA Container Toolkit access.
- **Service-level monitoring (KE-8 gap - REMEDIATED 2026-06-08):** previously
  alerting covered only `NodeDown` (node_exporter) + disk, not service ports.
  Now `blackbox_exporter` on lxc200 probes 7 services (HTTP + Serve-HTTPS) with a
  `ServiceDown` rule; Tailscale ACL Rule 1c grants monitoring the service ports.
  First run already caught paperless + openwebui returning 502 (dead backends).
- **journald persistence on vm100/vm102 - the previously recorded gap does not exist
  (verified 2026-07-10, as root):** both nodes have `/var/log/journal/<machine-id>/`. vm100
  retains 86 boots back to 2025-12-27, vm102 64 boots back to 2026-02-14, and the KE-8
  window (2026-06-08/09) holds 16,905 and 7,868 journal lines respectively. `Storage=` is unset,
  so `auto` applies, which is persistent whenever `/var/log/journal` exists. Remaining (minor)
  hardening: pin `Storage=persistent` and an explicit `SystemMaxUse=`, because `auto` makes
  persistence a property of a directory that happens to exist rather than of the config, and
  it degrades silently to RAM-only if that directory is ever removed.
- **unattended-upgrades on vm100 - restricted 2026-07-10.** The real defect was not the missing
  kernel exclusion but the origin list: the stock config allowed
  `"${distro_id}:${distro_codename}"`, i.e. the *regular* archive, not just security, with an
  empty `Package-Blacklist`. Now security pockets only, with `linux-image`/`linux-headers`/
  `linux-generic`/`linux-modules`/`nvidia-`/`libnvidia-` blacklisted, via the `unattended_upgrades`
  role. Kernel and driver upgrades belong in `apt-upgrade.yml`, run while someone is watching.
  Note the `#clear` directives in the drop-in are load-bearing - APT *appends* to a list option
  when it is redeclared, so without them the regular archive would have stayed enabled.
  **vm100 is Ubuntu 22.04** (`/etc/os-release`, verified 2026-07-10) - the only non-Debian node;
  vm102 and every LXC are Debian 12. The role's origin ids and package names are Ubuntu-specific
  and do not transfer unchanged, which is why it targets `hosts: vm100` and not a group.
- **LXC220 (Calibre-Web) tagged `tag:tier1`, not `tag:tier2` (rationale being reconfirmed):**
  application service tiering exception, confirmed intentional 2026-07-08. The
  `calibre-importer` role's auto-import mechanism has no verified dependency on
  tier1 access (SMB-only; tier1 and tier2 grant port 445 identically). Untrusted
  devices don't need Calibre-Web access, so no functional gap results. See the
  Tier Model exception note in `docs/platform/tailscale-acl.md`.
- **MergerFS pool close to full on vm102 (by design; alert tiering done 2026-07-10):** the media
  archive is meant to fill; read-only consumers (Jellyfin/ABS/Calibre) are unaffected, but write
  consumers (Nextcloud/Paperless/Vaultwarden/Postgres-backups, whose `/mnt/backups` target sits on
  this pool) will eventually hit `ENOSPC` - capacity expansion is the lever, not deletion.
  `DiskSpaceCritical` used to fire 21 times at once for this single fact: the pool, its five
  member disks, and the twelve CIFS mounts through which other nodes view it. Percentage is the
  wrong measure for a multi-terabyte archive: 15% of one is a large absolute amount, a threshold
  a pool designed to fill will never meet again. The rule now excludes `cifs`, `fuse.mergerfs`
  and the member disks; the new `ArchivePoolLowSpace` warns on absolute free bytes below
  100 GiB with `for: 1h`. The current margin is small and shrinking.

- **LXC250 SSH reachability after reboot:** sshd binds only to the Tailscale IP
  (`ListenAddress` in sshd_config). SSH is unreachable for ~30-60 s after boot until
  Tailscale connects. Use `pct exec 250 -- bash` from the Proxmox host as immediate
  fallback, or wait. This is intentional hardening, not a bug.
- **LXC260 boot dependency on SMB mount:** `mp1` binds `/mnt/smb/postgres-backups` into
  the container. After a hard shutdown, LXC260 may fail to start with pre-start hook
  exit 19 (`ENODEV`) if VM102/storage is still booting. Fix: wait for VM102, verify
  `ls /mnt/smb/postgres-backups` on the Proxmox host, then `pct start 260` manually.
- **`homelab_schedule` role not yet applied to live host (2026-06-17):** role deploys
  `homelab-setwake.sh` + `homelab-shutdown.sh` + `/etc/cron.d/homelab-schedule` via Ansible.
  Scripts and cron file currently managed manually. Run `--check --diff` first, then apply.
  After 2026-07-10 this is the last homelab-authored cron job - every guest-side job we wrote
  is now a systemd timer. Cron is defensible *here*: this job is what powers the host down, so it
  cannot depend on the host being up, and `Persistent=true` catch-up semantics would be actively
  wrong for a shutdown trigger. Decide explicitly when applying the role rather than porting it to
  a timer by reflex. (Distro- and upstream-owned cron remains and is correct: `e2scrub_all`,
  `sysstat`, `php` sessionclean - which self-disables under systemd - and lxc210's
  `/etc/cron.d/nextcloud`, running `cron.php` every 5 min, where there is nothing to catch up.
  Fleet audited 2026-07-10: no other root or user crontab holds an active entry.)
- **The last three orphaned scripts were adopted into roles on 2026-07-10** - `paperless_inbox_scan`
  (lxc210), `jellyfin_watchdog` (vm100), `snapraid_maintenance` (vm102). All three were
  hand-deployed to `/usr/local/sbin/` and scheduled from a crontab, so each would have been lost
  on a node rebuild. All three now ship a script + service unit + timer, and each role deletes the
  crontab entry it replaces. `ansible.builtin.cron` cannot remove a hand-written entry (it only
  recognises the `#Ansible: <name>` marker it writes itself), so the roles filter the crontab with
  `sed -E '/pat/d' | crontab -u root -` - `grep -v` would exit 1 when it prints nothing, which on a
  single-entry crontab is exactly what success looks like. vm100's root crontab is now empty.
- **Jellyfin CUDA access loss intermittent (KE-10):** hardware transcoding stops randomly; root
  cause unconfirmed (NVML connection goes stale). Workaround: `docker restart jellyfin`. Watchdog
  automates this but does not fix the root cause. See `docs/platform/known-errors.md#ke-10`.
  It last fired on 2026-08-07 and 2026-08-10 (watchdog journal, read 2026-08-13) - the fault is
  live, not historical, and each occurrence is absorbed silently, so nothing alerts.
- **postgres_exporter on LXC260 - bind fixed and unit adopted 2026-07-10.** It had bound `*:9187`
  (LAN-exposed) because the hand-written unit's `ExecStart` carried no `--web.listen-address`. The
  deferred design question ("drop-in or full lifecycle?") answered itself once measured: the unit
  is a *local* file in `/etc/systemd/system`, not a package's, so there was nothing to override -
  the new `postgres_exporter` role simply owns it. It binds the node's Tailscale IP, orders after
  `tailscaled` (the exporter would otherwise hit the KE-9/KE-12 bind race at boot), and asserts the
  hand-installed binary and env file exist rather than deploying a unit that cannot start.
  `/etc/postgres_exporter.env` still holds `DATA_SOURCE_NAME` unmanaged - adopting that needs an
  Ansible Vault step and is deliberately not bolted onto a bind-address fix.
- **Legacy SSH keys on vm100 + vm102 - REMOVED 2026-07-10.** The old entry named the wrong keys:
  `admin-laptop` is a *declared* break-glass key in `group_vars/vms.yml`, not an artefact. The
  actual strays, present on both VMs' admin accounts, were `root@server` (an RSA key belonging
  to no current machine) and `devops@devops-lxc` (the control node's interactive user on the admin
  account; Ansible connects as the `ansible` user with its own `authorized_keys`, so removing it
  cost no automation path). The `breakglass` role now enforces the key set with `exclusive: true`,
  making the inventory the single source of truth, and keeps a one-time
  `authorized_keys.pre-ansible` backup. `ssh <admin>@<node>` from lxc250 no longer works by design;
  `ssh ansible@<node>` and break-glass from either admin machine do.
- **Calibre library on CIFS - SQLite workaround in place, no durable fix:** `metadata.db` cannot
  safely live on CIFS (byte-range locking). Workaround: local-copy + atomic swap during import
  (see `calibre_importer` role). Moving library to local block storage is the durable fix but
  deferred (no extra volume available). See `docs/decisions/calibre-cifs-sqlite-import.md`.
- **Host CIFS mounts must carry `x-systemd.automount` - this is not optional (KE-15, RESOLVED
  2026-07-14):** the Proxmox host mounts `/mnt/smb/*` from vm102, a guest it starts itself, so
  at boot the SMB server does not exist yet. A plain fstab entry is tried once, fails
  (`mount error(113)`), and `nofail` lets the boot proceed while systemd never retries - the unit
  stays `failed` forever, the container bind exposes the empty directory on `pve-root`, and the
  service inside fails silently. That is exactly what happened: `/mnt/smb/books-rw` was the one
  entry missing the option, and `calibre-import.service` failed every 2 minutes for a month.
  No boot ordering can fix this class; only lazy, on-access mounting can. Audit with
  `grep '/mnt/smb/' /etc/fstab | grep -v x-systemd.automount` - it must print nothing. A container
  whose bind was set up while the mount was down does not heal by itself: `pct reboot <ctid>`.
  See `docs/platform/known-errors.md#ke-15`.
- **Samba cannot bind an IPv4 address on `tailscale0` (vm102):** the interface is a point-to-point
  TUN device without the `BROADCAST` flag, and Samba's IPv4 interface selection skips it. Verified
  2026-07-14 with `<ip>/32`, the bare IP, and the interface name - an explicit `interfaces` list
  *removes* the Tailscale SMB path instead of securing it, so `bind interfaces only = no` stays,
  deliberately. The boundary is enforced one layer down instead: the nftables table `inet
  smb_guard` on vm102 (`smb-guard.service`) drops inbound TCP/445 over IPv6 on the LAN interface
  and accepts IPv4 only from vm100 and the Proxmox host. **It must never be loaded via
  `nftables.service`** - the stock `/etc/nftables.conf` starts with `flush ruleset` and its
  `ExecStop` flushes everything, either of which wipes Tailscale's own chains. Do not "fix" the
  bind: read `docs/decisions/smb-bind-and-lan-access.md` first.

- **Alerting on failed systemd units (KE-15 gap - REMEDIATED 2026-07-10):** previously a unit in
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

- **The `Ansible-lint` workflow lints *every* branch, `Validate Repository` does not.** Its trigger
  is a bare `on: push:` with no `branches:` filter; only its `pull_request:` trigger is scoped to
  `main`. So a feature branch that is pushed but has no PR still sends a red-build mail - which is
  exactly how three red runs sat unnoticed on `chore/platform-techdebt-2026-07-10` on 2026-07-10
  while `main` stayed green. This is a feature, not a defect: the alternative is discovering the
  findings at PR time. The pre-commit gap that let them through in the first place is closed by
  `validate-repo.sh` Check 16, which is inert unless `ansible-lint` is installed locally
  (`pipx install 'ansible-lint==26.6.0'` - the pin must match `.github/workflows/ansible-lint.yml`).

- **`ansible-lint`'s `command-instead-of-module` rule has an upstream gap on `systemctl`:** the
  rule carries an allow-list of subcommands with no module equivalent
  (`_executable_options["systemctl"]` in `ansiblelint/rules/command_instead_of_module.py`). It
  contains `reset-failed` but not `is-failed`, so in `systemd_hygiene` only one half of an adjacent
  pair of `systemctl` calls is flagged. Neither has a module: `systemd_service` has no query-only
  mode and errors on a unit whose file was just deleted, and `service_facts` sees `.service` units
  only - half of `systemd_hygiene_masked_units` are `.mount` units. Waived inline with
  `# noqa: command-instead-of-module`, never in `skip_list`, so the rule stays armed repo-wide.
  Read the rule's source before assuming a lint finding names a real defect.
- **PostgreSQL backups: scheduling fixed 2026-07-10, restore validated 2026-08-13.** They had not
  run since 2026-06-14 because the role scheduled a cron job at 03:00 on a host that
  `homelab_schedule` powers down overnight - cron has no catch-up, so every run was silently
  lost; the four dumps that existed came from nights the host happened to stay up. Replaced with
  a systemd timer + `Persistent=true` (fires an overdue run at the next boot). A failed timer
  unit now also raises `SystemdUnitFailed`; a cron failure never did. **Any daily job on this
  fleet must be a timer with `Persistent=true`, not a cron entry** - the host is not up at night.
  Restore validation is no longer absent - a full-cluster restore into a throwaway cluster passed
  on 2026-08-13 (procedure and result in the runbook's Verification section) - but it is still
  **manual and unscheduled**, and the dumps are never checked for readability at write time.
  The `-mtime +7` retention means a single bad dump plus a week of silence loses everything.

- **`tailscale cert` on disk needs a reload, not just a renewal (KE-16):** on nodes that read
  `/var/lib/tailscale/certs/*.crt` directly (only lxc210 - everything else goes through
  `tailscale serve`, which renews transparently), `tailscaled` renews the file but the consuming
  daemon keeps the old certificate in memory. Apache served an expired certificate for an hour
  with a valid one lying next to it. Handled by the `tailscale_cert` role and the
  `tailscale_cert_ondisk` inventory group. Never add a serve-backed node to that group.

- **Apache on lxc210 binds `*:80` and `*:443` (LAN-exposed), violating the platform binding rule:**
  same defect class as vm100's sshd. MariaDB and Redis on the same node bind single addresses
  correctly. Fixing it means either pinning `Listen` to the Tailscale IP (which couples Apache's
  start to Tailscale being up - the KE-9/KE-12 boot-race class) or moving Nextcloud behind
  `tailscale serve`, which would also retire the whole KE-16 renewal problem. Needs its own
  design decision; do not bolt it onto an unrelated pass.

- **lxc200 monitors the fleet but not itself:** `node-exporter.yml` runs against `all:!lxc200`,
  because lxc200's node_exporter is a Docker container that cannot see the host's systemd units.
  lxc200 is now the only node without `SystemdUnitFailed` coverage: its exporter cannot see
  systemd. lxc250 was the second until 2026-08-20, for the different reason that nothing
  scraped it; it is in the inventory and scraped since. The Proxmox host was the
  second blind spot until 2026-07-14 and is now covered. Needs its own design decision (privileged
  container with `/run/systemd` bind-mounted, or a native node_exporter alongside the container).
- **The Proxmox host's `node_exporter` is hand-managed and would be lost on a rebuild
  (2026-07-14):** it now runs `--collector.systemd` (it had only the textfile collector, so a
  failed unit on the *hypervisor* reached no alert - the gap that would have made
  `smb-mounts-check.service` another silent guard) and binds `100.x:9100` instead of `*:9100`,
  which had been LAN-exposed in violation of the binding rule. Both changes were made by hand,
  at a time when the host was not an Ansible node. It became reachable as one on 2026-08-21, so
  the `node_exporter` role can now own this properly - the debt is unblocked, not yet paid.
  **The trap this entry used to name is gone, corrected 2026-08-15:** it warned that adopting the
  host needs `host_vars` with `node_exporter_textfile_dir` set or the role silently drops the
  textfile collector. That stopped being true on 2026-07-10 (`c134959`), when the default became
  fleet-wide precisely because the per-host form had already cost vm102 its SnapRAID metrics once.
  Verified 2026-08-15: the host's hand-written unit uses the identical path, so adoption needs no
  override at all. The general lesson is about the warning, not the flag - a documented trap
  outlives its fix, keeps being repeated, and quietly deters the work it was meant to protect.
  See the host-adoption design decision (pending).
- **VM100 cannot be rolled back - no snapshot is possible (found 2026-08-16):** its `scsi1` is a
  300 GB raw file on directory storage, a format Proxmox cannot snapshot, and that storage sits on
  the failing KE-13 disk. The thin pool holding `scsi0` is at 84 % with no free space at all in the
  volume group, so growing it is not an option either. Every change to this VM is therefore more
  expensive than it looks: there is no way back except a restore that does not exist. This became
  concrete when a live CIFS unmount froze the guest with no evidence recorded
  ([KE-20](docs/platform/known-errors.md#ke-20)) and only `qm stop` recovered it. Making VM100
  snapshottable - moving that disk to snapshot-capable storage, off the KE-13 disk - is the
  precondition for investigating KE-20 and for any non-trivial maintenance on this node.
- **Off-site backups not implemented:** current backups are local only (SMB on VM102). No
  protection against full-site loss or ransomware. Critical subsets (Vaultwarden export,
  Nextcloud DB, Paperless documents) have no off-site copy.
- **SMART monitoring is partly deployed, and the deployed part cannot detect the failure it exists
  for (entry corrected 2026-08-10 after measuring the host).**
  `/usr/local/sbin/node-exporter-smarttext.sh` has been running on the host every 60 s since
  2025-12, emitting `smart_health_passed` and `smart_temperature_celsius` for all nine disks. But
  `smart_health_passed` reads 1 (PASSED) for the aux-disk with 7680 unreadable sectors, exactly
  as KE-13 records (`Current_Pending_Sector` normalises to 054 against threshold 000 and can never
  trip the self-assessment). The attributes that matter - `Reported_Uncorrect`,
  `Current_Pending_Sector`, `Reallocated_Sector_Ct`, `Wear_Leveling_Count` - are not exported,
  and the `smart` rule group in `alert.rules.yml` is still `rules: []` with a comment assuming
  `smartctl_exporter` metric names that do not exist here. So the collector is real and the gap is
  real: metrics exist, the ones that would have caught KE-13 do not. Disk failure detection still
  relies on SnapRAID alerts. **This gap is why KE-13 ran to total failure unnoticed, and why the disk was
  returned to service without anyone seeing it still degrading.** Note: all nine disks are attached
  to the Proxmox host; VM102 reaches seven of them via `by-id` passthrough and sees only
  virtio-SCSI devices, so SMART is readable *only on the host* - the previous wording here named
  VM102 as the target node and was wrong. Deploying this requires the host to become an
  Ansible-managed node, the same prerequisite `homelab_schedule` is waiting on.
  Listed as planned enhancement in `docs/platform/operations.md`.
- **LXC250 (control node) tracks `main` only - verify before every live run:** playbooks execute
  from the working tree, not from a commit, so a node on a feature branch or mid-merge silently runs
  code matching no commit. Update with `git pull --ff-only`; do feature work on a workstation. Before
  a run that changes live state: `git status --short --branch` must show a clean `main`, and
  `grep -rlE "^(<<<<<<<|=======|>>>>>>>)" ansible/` must print nothing. `validate-repo.sh` Check 15
  only catches markers that reach a commit. (Found mid-merge on 2026-07-09; resolved.)
- **VM100 sshd binds `0.0.0.0:22` (LAN-exposed), violating the platform binding rule:** unlike
  lxc250, which pins `ListenAddress` to its Tailscale IP. Password auth is off since 2026-07-09,
  so the acute risk is closed, but the bind is wrong and contradicts vm100.md's own "LAN exposure
  limited to 8096/13378 only". Fixing it couples sshd startup to Tailscale being up - the
  KE-9/KE-12 boot-race class. Needs its own design decision, including whether `ssh_hardening`
  should own `ListenAddress`. Do not bolt this onto an unrelated pass.
- **KE-14 - boot-time I/O errors on the boot SSD, root cause unconfirmed:** intermittent
  `DID_SOFT_ERROR` bursts against the boot SSD (LSI SAS2008 HBA) during the boot window only.
  Media and HBA-firmware causes are excluded; leading hypothesis is a sagging 12 V rail.
  Requires physical verification (multimeter, cable reseat, HBA temperature, PSU age).
  The boot SSD (`scsi 9:0:0:0`, never a fixed kernel letter) carries every VM and LXC root disk,
  so an `EIO` into the thin pool during guest start could corrupt a guest filesystem. See `docs/platform/known-errors.md#ke-14`.
- **aux-disk is back in service with 7680 unreadable sectors (KE-13), replacement pending:**
  it carries the Docker data-roots of LXC200/211/220/230/260 and VM100's `scsi1` disk
  (allocated). `Reported_Uncorrect` rose 18 -> 21 between the 2026-06-25 incident and 2026-07-09,
  but has been static at 21 since (re-read 2026-07-28), as has `Current_Pending_Sector` at 7680.
  The failure is not accelerating; see the KE-13 note in Current Status for why that is not the same
  as safe. Nothing on `/mnt/aux-disk` has an off-site copy.
- **Standing hold on `docker-compose-update` (until aux-disk is replaced):** the role pulls new
  images, writing gigabytes of fresh blocks onto that disk. The repo-side image pins and the
  role's compose-file-sync fix can wait for the replacement.
- **`appdata_aux-disk` storage lacks `is_mountpoint 1` (host change, deferred):** if aux-disk fails to
  mount, Proxmox treats the storage as active and writes into the empty mountpoint on `pve-root`,
  filling the boot SSD - the KE-7 failure class. `mkdir 0` does not prevent this.
- **LVM thin-pool fill - RESOLVED 2026-08-10.** `pve/data` had gone 86.15 % (2026-07-28) -> 92.55 %
  in thirteen days with no rule able to see it, because a thin pool is a block-layer object with no
  filesystem and `node_filesystem_*` cannot observe it. Now covered by `lvm-thin-metrics.sh`, a
  node_exporter textfile collector on the host (60 s), plus `LvmThinPoolWarning` / `Critical` /
  `MetadataCritical` / `LvmThinMetricsStale`. Reclaimed to 81.20 % by `pct fstrim` and kept there by
  `lxc-fstrim.timer` - containers cannot trim themselves: the stock `fstrim.timer` carries
  `ConditionVirtualization=!container` and the ioctl is refused anyway, both silently. Note
  `lvm_vg_free_bytes` reads 0: the VG is fully allocated, so `lvextend` is not an available remedy
  without shrinking `root`/`swap` or adding a PV. Units are hand-deployed; folding them into a role
  waited on the host becoming an Ansible node, which happened on 2026-08-21.
- **`tailscaled-userspace.service` on lxc220 is disabled, not deleted (2026-07-28):** the KE-6
  recurrence was closed by `systemctl disable --now`, which stops it returning at boot but leaves
  the unit file in `/etc/systemd/system/`. A future `systemctl enable` or a rebuild from this
  machine's state would revive it. Remove the file during the next lxc220 pass.

## Platform Changelog

The full platform changelog lives in [`docs/platform/changelog.md`](docs/platform/changelog.md) (reverse chronological), kept out of this file so the always-loaded instruction context stays small. Detailed ACL changes are in `docs/platform/tailscale-acl.md#changelog`. When recording a new platform change, append it there, not here.

## Adding a New Service

1. Before implementation: link official upstream docs, identify relevant sections, wait for confirmation
2. Create `docs/services/<service>.md` with an `## Access Model` section referencing `docs/platform/tailscale-acl.md`
3. Create `docs/nodes/<node>.md` with a `## Failure Impact` section
4. Add the node's Tailscale tag to `docs/platform/tailscale-acl.md` (tier model, tag ownership, ACL rules, access matrix, changelog)
5. If Docker-based: add `docker/<service>/docker-compose.yml` and `docker/<service>/.env.example`; use pinned version tags (not `:latest`)
6. If Docker-based: configure Docker engine data root on aux-disk from the start - set `data-root` in `/etc/docker/daemon.json` and `root` in `/etc/containerd/config.toml` to point to a subdirectory of the node's aux-disk mount (e.g. `/var/lib/<service>/containerd` and `/var/lib/<service>/docker-data`); prevents SSD thin-pool pressure from image accumulation
7. Run `./scripts/validate-repo.sh` and fix all errors
