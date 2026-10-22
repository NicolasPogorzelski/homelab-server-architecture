# Working Rules for Claude Code

Instructions for Claude Code when it works in this repository. How AI assistance is used here is
described in the [README](README.md#how-this-repository-is-built). This file holds rules only: no
platform facts, no status, no dates. Those live in the documents that own them.

## Where things are

- Conventions, document types, length ceilings, fact owners: [`docs/CONVENTIONS.md`](docs/CONVENTIONS.md).
  Read it before writing anything.
- Current state: the node, service and platform documents. Open work:
  [`remediation-plan.md`](docs/platform/remediation-plan.md). Faults:
  [`known-errors.md`](docs/platform/known-errors.md). History: `git log` and merged pull requests.
- A fact that changes is changed in its owner file. It is never repeated here or anywhere else.

## Two modes

- **Maintenance**, the default: the assistant drafts the change (documentation, roles, playbooks,
  scripts) and shows it; a person reviews the diff and merges.
- **Learning**, only when started with `/rolle tutor`: the person writes the first version from an
  empty file; the assistant explains, researches and reviews afterwards, and does not write the
  solution. The role is defined in the `dotfiles` repository and ends with the session.

Documentation is drafted by the assistant in both modes, including the README, decision records
and known-error entries; the person reviews and curates it before it is committed.

Every design decision belongs to the person. The assistant advises, measures and drafts.

## Risks noticed in passing

A risk the assistant notices while working on something else (a secret in clear text, possible
data loss, an open access path) is named in one line. It is not searched for and not acted on.
A full review from four seats (IT security, OT security, DevSecOps, DevOps) is started with
`/rolle devsecops`; widening the task is proposed there, not performed, above all where it
changes what a security control examines.

## Working method

- Root cause before fix: symptom, verification command, diagnosis, fix.
- Small steps, each verified before the next.
- When unsure, say so. No guessed flags, paths or behaviour; for a new tool, link the official
  documentation first.
- Commands are specific to the OS they run on: Proxmox VE on Debian, Debian LXCs and vm102,
  Ubuntu on vm100, an rpm-ostree workstation.
- Name the class of a fault and link the instances already recorded in `known-errors.md`.

## Drafting

The rules in the Writing section of `docs/CONVENTIONS.md` apply. Drafts by the assistant
additionally avoid the patterns that make generated text recognisable:

- "X, not Y" only where it separates a real misdiagnosis from the cause.
- No "rather than", "deliberately" or "by design" as filler; say what was chosen and why.
- No maxims, no closing punchlines, no sentences about the document itself.
- No narration of the change ("now", "was changed to"); git records the change.
- Templates carry the structure; sentences inside them do not all open the same way.
- Comments say why a value is what it is, in one to three lines.

The `prose-tics` agent checks a draft against these rules before it is committed.

## Fleet access

- Read-only unless a change is explicitly approved.
- Playbooks run from lxc250 with `--check --diff` first; the diff is shown before any apply.
- Sanitize by placeholder as `docs/CONVENTIONS.md` defines. Nothing about the owner goes in:
  describe the shape of a removed value, never the value.

## Validation and commits

- `./scripts/validate-repo.sh` passes before every commit. `scripts/hooks/pre-commit-guard.sh`,
  registered in `.claude/settings.json`, refuses a commit on `main` or with findings.
- `git config core.hooksPath scripts/hooks` installs the `commit-msg` hook, which runs
  `scripts/commit-msg-lint.sh`.
- Conventional Commits with a scope, in English, one topic per commit.
- No attribution trailers and no tool names in commit messages, pull request titles or bodies.

## Publishing

- The assistant may push feature branches (`feat/`, `fix/`, `docs/`, `chore/`, `refactor/`,
  `test/`, `ci/`) and nothing else. Pull requests, merges and releases are a person's step in
  GitHub. A global PreToolUse hook (`publish-guard.sh` in the `dotfiles` repository) and the
  `main-protection` ruleset enforce this.
- Before a push, the branch is reviewed in the conversation: the full diff, one line per commit,
  what becomes public, the validator output quoted, and the commands to run.

## Agents

`.claude/agents/` holds `state-claims` (documents against the live fleet) and `prose-tics`
(writing). For every agent:

- An agent is never the mechanism of a control. Timers, metrics and rules decide; an agent
  proposes and drafts.
- A report separates "measured and clean" from "could not be measured".
- The `tools:` field grants the least that the task needs.

## End of a unit of work

State per repository touched (branch, commits waiting, how it publishes), the validator output
quoted, the commands in execution order, what was left undone and why, and the first open item.
None of it is recorded in this file.
