#!/usr/bin/env bash
#
# Claude Code PreToolUse hook. Reads the tool call on stdin and blocks it when it
# would commit while the repository is not in a committable state.
#
# Two things it refuses:
#   1. a commit made directly on main - work belongs on a branch and reaches main
#      through a pull request, which is also what the GitHub ruleset enforces
#   2. a commit while validate-repo.sh reports findings
#
# Written 2026-08-17, after discovering that CLAUDE.md had documented this gate
# for weeks while no hook was configured. The validation had been running only
# because somebody remembered to run it. A guard that exists on paper is the
# failure mode this repository keeps finding in its own monitoring, and it turned
# out to apply to the tooling as well.
#
# Two deliberate differences from the earlier reference version in
# snippets/claude/hooks-reference.json:
#
#   - It matches `git ... commit` anywhere in the command string rather than
#     relying on a `Bash(git commit *)` prefix rule. Commits here are usually part
#     of a compound command (`git add -A && git commit -F -`), which a prefix rule
#     never sees. A guard that misses the normal case is decoration.
#   - It answers with permissionDecision "deny" rather than continue:false. Deny
#     blocks the single tool call and leaves the session running, so the findings
#     can be fixed and the commit retried; continue:false ends the turn.
#
# Exit code is always 0. A hook that fails noisily on its own bugs would block
# every commit, so the only way it speaks is the JSON on stdout.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

deny() {
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}' \
        "$(printf '%s' "$1" | jq -Rs .)"
    exit 0
}

command_line="$(jq -r '.tool_input.command // ""' 2>/dev/null)"

# Not a commit: say nothing, let the call through.
printf '%s' "${command_line}" | grep -qE '\bgit\b[^|;&]*\bcommit\b' || exit 0

branch="$(git -C "${REPO_ROOT}" branch --show-current 2>/dev/null || true)"
if [ "${branch}" = "main" ]; then
    deny "Direct commit on main is blocked. Create a branch first; main is reached through a pull request, which the GitHub ruleset also enforces."
fi

if findings="$("${REPO_ROOT}/scripts/validate-repo.sh" 2>&1)"; then
    exit 0
fi

deny "$(printf 'validate-repo.sh reports findings, so the commit was blocked. Fix these, then commit again.\n\n%s' \
    "$(printf '%s' "${findings}" | grep -E '^  |^FAIL' | grep -v 'SKIP:' | head -20)")"
