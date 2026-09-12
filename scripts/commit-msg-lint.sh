#!/usr/bin/env bash
set -euo pipefail

# Commit message gate. Two rules:
#
#   1. Conventional Commits with a scope, checked on the subject line.
#   2. No AI attribution anywhere in the message, checked on the whole text.
#
# Rule 2 was added on 2026-09-12, after nine commits carrying a
# `Claude-Session: https://claude.ai/...` trailer reached the public `main`
# branch. The policy forbidding it had been in CLAUDE.md since the repository was
# written; nothing read it. This script existed and looked only at the subject
# line, so a trailer at the foot of the body passed without being examined.
#
# Usage:
#   commit-msg-lint.sh <file>      # git commit-msg hook, and CI over a PR range
#
# CI runs it over every commit in a pull request and over the pull request's own
# title and body (.github/workflows/commit-messages.yml). That is the gate that
# matters: this script as a git hook is per-workstation state, and measured on
# 2026-09-12 the admin notebook had no .git/hooks/commit-msg at all - so the
# local half had never run once. validate-repo.sh Check 40 reports that absence
# rather than leaving it to be discovered again.

# --attribution-only applies rule 2 alone. Used for a pull request's title and
# body, which are prose and were never meant to be Conventional Commits.
ATTRIBUTION_ONLY=0
if [[ "${1:-}" == "--attribution-only" ]]; then
    ATTRIBUTION_ONLY=1
    shift
fi

MSG_FILE="$1"
SUBJECT="$(head -1 "$MSG_FILE")"
BODY="$(cat "$MSG_FILE")"

# Auto-generated subjects are exempt from rule 1 and never from rule 2. A revert
# quotes the message it reverts, so reverting one of the nine commits that
# already carry the trailer will be refused - correctly, and the way out is to
# edit that quoted body by hand, which is a deliberate act on a rare occasion.
SKIP_FORMAT=0
if echo "$SUBJECT" | grep -qP '^(Merge|Revert|fixup!|squash!)'; then
    SKIP_FORMAT=1
fi

# ---------------------------------------------------------------------------
# Rule 1: Conventional Commits, scope required
# ---------------------------------------------------------------------------
PATTERN='^(feat|fix|docs|refactor|chore|test|ci)\([a-z0-9-]+\): .+'

if (( SKIP_FORMAT == 0 )) && (( ATTRIBUTION_ONLY == 0 )) && ! echo "$SUBJECT" | grep -qP "$PATTERN"; then
    echo "ERROR: Commit message format invalid." >&2
    echo "Expected: type(scope): description" >&2
    echo "Types:    feat fix docs refactor chore test ci" >&2
    echo "Got:      $SUBJECT" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Rule 2: no AI attribution
# ---------------------------------------------------------------------------
# The repository names its tooling on purpose - CLAUDE.md is a tracked file, the
# hook scripts live in scripts/hooks/, and lxc250-rebuild.md documents installing
# the CLI. Naming a file this repository contains is not attribution, and commit
# bodies have referred to CLAUDE.md since long before this rule. So the literal
# filename and the two directory paths are removed from the text first, and what
# survives is what the rule judges.
#
# The distinction to hold on to: describing the tool as part of the platform is
# documentation; marking authored work as produced by it is attribution. Only the
# second is forbidden, and the first is what the stripping below permits.
STRIPPED="$(printf '%s' "$BODY" \
    | sed -E 's#\bCLAUDE\.md\b##g; s#\bsnippets/claude/#/#g; s#(^|[^a-zA-Z0-9])\.claude/#\1#g')"

AI_PATTERN='claude|anthropic|chatgpt|openai|copilot|co-authored-by|ai-generated|generated with'

# The robot emoji that the usual generated trailer opens with, matched by code
# point so this file stays plain ASCII - validate-repo.sh Check 19 forbids the
# character itself, and a gate that cannot pass the repository's own checks is
# not a gate anybody keeps.
if printf '%s' "$STRIPPED" | grep -qP '\x{1F916}'; then
    echo "ERROR: Commit message carries the generated-by robot emoji." >&2
    exit 1
fi

if MATCH="$(printf '%s' "$STRIPPED" | grep -inE "$AI_PATTERN" | head -3)"; then
    echo "ERROR: Commit message references an AI tool or carries an attribution trailer." >&2
    echo "CLAUDE.md, Commit Policy: never add Co-Authored-By or any AI attribution" >&2
    echo "trailer, and never reference AI tools in commit messages." >&2
    echo "" >&2
    echo "Offending line(s):" >&2
    printf '  %s\n' "$MATCH" >&2
    echo "" >&2
    echo "Naming the file CLAUDE.md is allowed; it is a file this repository contains." >&2
    exit 1
fi
