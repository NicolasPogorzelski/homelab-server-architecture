#!/usr/bin/env bash
set -euo pipefail

# Commit message gate. Rules:
#
#   1. Conventional Commits with a scope, checked on the subject line.
#   2. No tool attribution in the message. Authorship is the commit author; how AI
#      assistance is used is stated once, in the README, not per commit.
#   3. Subject at most 72 characters; GitHub cuts a longer pull request title.
#   4. Pull request only: the template's "What and why" section carries text.
#
# Usage:
#   commit-msg-lint.sh <file>                  # commit-msg hook and CI, rules 1-3
#   commit-msg-lint.sh --no-length <file>      # Dependabot commits, rules 1-2
#   commit-msg-lint.sh --pull-request <file>   # title as subject, then body; rules 1-4

PULL_REQUEST=0
CHECK_LENGTH=1
case "${1:-}" in
    --pull-request) PULL_REQUEST=1; shift ;;
    --no-length) CHECK_LENGTH=0; shift ;;
esac

MSG_FILE="$1"
SUBJECT="$(head -1 "$MSG_FILE")"
BODY="$(cat "$MSG_FILE")"

# Generated subjects (merge, revert, fixup) are exempt from rule 1, not from rule 2.
SKIP_FORMAT=0
if echo "$SUBJECT" | grep -qP '^(Merge|Revert|fixup!|squash!)'; then
    SKIP_FORMAT=1
fi

# ---------------------------------------------------------------------------
# Rule 1: Conventional Commits, scope required
# ---------------------------------------------------------------------------
PATTERN='^(feat|fix|docs|refactor|chore|test|ci)\([a-z0-9-]+\): .+'

if (( SKIP_FORMAT == 0 )) && ! echo "$SUBJECT" | grep -qP "$PATTERN"; then
    echo "ERROR: Commit message format invalid." >&2
    echo "Expected: type(scope): description" >&2
    echo "Types:    feat fix docs refactor chore test ci" >&2
    echo "Got:      $SUBJECT" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Rule 2: no AI attribution
# ---------------------------------------------------------------------------
# File names of the local assistant configuration may be named (for example in a
# .gitignore change); they are removed before the rule is applied.
STRIPPED="$(printf '%s' "$BODY" \
    | sed -E 's#\bCLAUDE\.md\b##g; s#\bsnippets/claude/#/#g; s#(^|[^a-zA-Z0-9])\.claude/#\1#g')"

AI_PATTERN='claude|anthropic|chatgpt|openai|copilot|co-authored-by|ai-generated|generated with'

# The robot emoji of generated trailers, matched by code point to keep this file ASCII.
if printf '%s' "$STRIPPED" | grep -qP '\x{1F916}'; then
    echo "ERROR: Commit message carries the generated-by robot emoji." >&2
    exit 1
fi

if MATCH="$(printf '%s' "$STRIPPED" | grep -inE "$AI_PATTERN" | head -3)"; then
    echo "ERROR: Commit message references an AI tool or carries an attribution trailer." >&2
    echo "Tool use is disclosed in the README; commits carry no attribution trailers" >&2
    echo "(see docs/CONVENTIONS.md, Commits and branches)." >&2
    echo "" >&2
    echo "Offending line(s):" >&2
    printf '  %s\n' "$MATCH" >&2
    echo "" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Rule 3: subject length
# ---------------------------------------------------------------------------
if (( SKIP_FORMAT == 0 )) && (( CHECK_LENGTH == 1 )) && (( ${#SUBJECT} > 72 )); then
    echo "ERROR: Subject is ${#SUBJECT} characters; the limit is 72." >&2
    echo "Got:      $SUBJECT" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Rule 4: the pull request template is filled in
# ---------------------------------------------------------------------------
if (( PULL_REQUEST == 1 )); then
    WHAT="$(printf '%s\n' "$BODY" \
        | awk '/^## What and why/ { on = 1; next } /^## / { on = 0 } on' \
        | perl -0pe 's/<!--.*?-->//gs' | tr -d '[:space:]')"
    if [[ -z "$WHAT" ]]; then
        echo "ERROR: The pull request body leaves \"What and why\" empty." >&2
        echo "Fill in the template from .github/pull_request_template.md." >&2
        exit 1
    fi
fi
