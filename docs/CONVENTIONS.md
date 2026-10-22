# Documentation Conventions

How documents in this repository are structured, how long they may get, and which file owns which
fact. `scripts/validate-repo.sh` enforces the mechanical parts; the rest is review.

## Principles

- **Documents describe the current state.** Git history is the record of how it got there. A
  sentence that starts "this used to say" is deleted, not added.
- **One fact, one owner.** A value lives in exactly one file. Every other document links to that
  file instead of repeating the value. See [Fact owners](#fact-owners).
- **Evidence beside every claim of state.** A command and its output, a check that enforces it, or
  a dated line `Verified 2026-10-12: ...`. A claim with none of these is a plan, and is written as
  one.
- **Length is a cost.** Documents have budgets (see [Document types](#document-types)). A detail
  that does not change what the reader does next moves to a linked document or is dropped.
- **Nothing personal.** Infrastructure is sanitized by placeholder; facts about the owner are left
  out. See [Sanitization](#sanitization).

## Fact owners

| Fact | Owner | Everyone else |
|---|---|---|
| Nodes, groups, addresses (placeholders) | `ansible/inventory/hosts.yml.example` | link to it |
| Node purpose, mounts, failure impact | `docs/nodes/<node>.md` | link to it |
| Schedules (timers) and their parameters | the role's `defaults/main.yml` | name the role, not the time |
| Image versions | `docker/<stack>/docker-compose.yml` | name the stack, not the version |
| Alert rules and thresholds | `docker/monitoring/prometheus/rules/alert.rules.yml` | `monitoring.md` table (validated) |
| Tailscale tags and grants | `docs/platform/tailscale-acl.md` | name the tag |
| Why something is built the way it is | `docs/decisions/` | link the decision |
| A fault, its cause and its fix | `docs/platform/known-errors.md` | link `KE-n` |
| Open work and its priority | `docs/platform/remediation-plan.md` | link the item |
| ISO/IEC 27001 control status | `docs/platform/security-controls.md` | link the row |
| Repository counts in the README | the repository itself | validated by `validate-repo.sh` |

## Document types

Budgets are ceilings, not targets. The validator fails a document above its ceiling.

| Type | Location | Ceiling (lines) | Required |
|---|---|---|---|
| README | `README.md` | 160 | counted claims validated |
| Assistant rules | `CLAUDE.md` | 120 | rules only: no dates, no status |
| Assistant agent | `.claude/agents/*.md` | 60 | `tools:` field, no dates |
| Assistant skill | `.claude/skills/*/SKILL.md` | 60 | `disable-model-invocation: true`, no dates |
| Decision record | `docs/decisions/*.md` | 130 | `## Status` |
| Node document | `docs/nodes/*.md` | 130 | `- Tag:` line, `## Configuration Management`, `## Failure Impact` |
| Service document | `docs/services/*.md` | 130 | `## Access Model` |
| Architecture view | `docs/architecture/*.md` | 180 | - |
| Platform document | `docs/platform/*.md` | 320 | - |
| Incident report | `docs/platform/incidents/*.md` | 160 | - |
| Runbook | `runbooks/**/*.md` | 180 | `Last exercised:` line, contract sections |
| Known-error entry | one `## KE-n` section | 70 | anchor, index row |

Exceptions with a reason are listed in the validator next to the ceiling check, so an exception is
visible in a diff.

### Decision record

```markdown
# <Decision as a short statement>

## Status
Accepted 2026-09-12. Supersedes / superseded by: <link or "-">.

## Context
What forced a decision. Facts and measurements, not history.

## Options
One line per option and why it lost. The chosen option last.

## Decision
What was decided, in two to five sentences.

## Consequences
What this costs, what it rules out, what has to be watched.
```

Allowed status words: `Proposed`, `Accepted`, `Implemented`, `Superseded`, `Withdrawn`.

### Node document

Purpose in one sentence, then: `- Tag:`, `## Resources`, `## Services`, `## Storage`,
`## Access Model`, `## Configuration Management` (roles that manage it), `## Failure Impact`,
`## Open Items` (links into the remediation plan, no prose duplicates). Current state only.

### Runbook

```markdown
# Runbook: <task>

- **Use when:** <trigger>
- **Duration:** <estimate>
- **Risk:** <what can go wrong>
- **Last exercised:** 2026-08-21, <result> | never

## Preconditions
## Steps
1. <command>
   Check: <command and expected output>
## Verification
## Failure modes
## Rollback
## Background
```

Steps come before background. Every destructive step is preceded by the step that makes it
reversible. `## Background` explains why a step works (what `systemctl reset-failed` clears,
why an order matters), so the runbook can be followed without knowing it already. It carries
no history.

### Known-error entry

```markdown
<a id="ke-n"></a>
## KE-n: <symptom as the reader sees it>

- **Status:** Open | Mitigated | Resolved 2026-09-11
- **Affects:** <nodes, services>

**Symptom.** What was observed, with the log line or metric.
**Cause.** The root cause, and the measurement that proves it.
**Fix.** What changed, with the role, commit or PR.
**Verification.** How the fix is known to work.
```

The status line is updated in place when the state changes. Superseded measurements are removed,
not appended to.

### Remediation item

One row in the ranked table at the top of `remediation-plan.md` (rank, item, risk, next step), and
a short section below it only when the next step needs more than one sentence. Closed items are
removed; the pull request that closed them is the record.

## Comments in code and configuration

- A comment says why a value is what it is, in one to three lines.
- Reasoning longer than that is a decision record or a known-error entry; the comment links it,
  for example `# see KE-14`.
- A file header may explain the whole file in up to fifteen lines. The validator refuses any run
  of more than twenty comment lines; a header that the script prints as its usage text is the
  listed exception.
- No dates of change, no history, no anecdotes. Git carries those.

## Writing

- English, always: documents, comments, commit messages, branch names, pull requests.
- ASCII punctuation only: `-`, `"`, `...`, `->`. Box-drawing characters inside diagrams and the
  section sign are the exceptions.
- Bold only as a label at the start of a line or list item.
- State the fact, then the evidence. No maxims, no closing punchlines, no sentences addressed to a
  reviewer.

| Instead of | Write |
|---|---|
| "An untested backup is a belief, not a control." | "The restore test runs monthly; `PostgreSQLRestoreTestStale` fires after 40 days without a pass." |
| "This line said monthly until 2026-09-15, which ..." | "Scrub runs weekly (`snapraid_maintenance` defaults)." |
| "The interesting part is ..." | the part itself |
| a measurement woven into a paragraph | `Verified <date>: <value>, by <command>.` on its own line |

## Sanitization

- Tailscale addresses: `<tailscale-ip-nodename>`. Tailnet name: `<tailnet-id>`.
- LAN addresses: `<lan-ip-nodename>`.
- Disks: `disk01`-`diskN` (SnapRAID data disks), `aux-pool` (auxiliary disk in the vm102 pool),
  `aux-disk` (auxiliary disk on the Proxmox host). Never a label that encodes size or purpose.
- No `.env` files, no keys, no certificates. Each compose directory carries a `.env.example`.
- No counts or fill levels that describe personal content.

## Commits and branches

- Conventional Commits with a scope: `docs(lxc260): ...`, `fix(monitoring): ...`. Scopes are node
  names or `monitoring`, `network`, `docs`, `adr`, `runbook`, `ci`, `repo`, `platform`.
- Branches use `feat/`, `fix/`, `docs/`, `chore/`, `refactor/`, `test/` or `ci/`.
- `main` is protected: changes arrive by pull request with the validation and lint checks green.
- `scripts/commit-msg-lint.sh` runs as the `commit-msg` hook (`git config core.hooksPath
  scripts/hooks`).

How AI assistance is used in this repository is stated in the [README](../README.md#how-this-repository-is-built);
the rules the assistant works under are in [CLAUDE.md](../CLAUDE.md).
