#!/usr/bin/env bash
#
# Claude Code PreToolUse hook (registered in .claude/settings.json). Refuses a Bash call that
# commits to this repository while it is on main, or while validate-repo.sh reports findings.
#
# It matches `git ... commit` anywhere in the command, so compound commands are covered; any
# command that mentions both words is treated as a commit, and a false refusal costs a retry.
# The target repository is resolved from `git -C`, a leading `cd`, or the session directory;
# the guard steps aside only for a worktree that is provably a different repository.
# Both roots come from `git rev-parse`, because `pwd` keeps symlinks (/home -> /var/home on
# rpm-ostree) and would never match.
#
# Exit code is always 0; a refusal is the JSON permission decision on stdout.

set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || true)"

deny() {
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}' \
        "$(printf '%s' "$1" | jq -Rs .)"
    exit 0
}

# stdin can be read once; the payload is needed twice.
payload="$(cat)"
command_line="$(printf '%s' "${payload}" | jq -r '.tool_input.command // ""' 2>/dev/null)"

printf '%s' "${command_line}" | grep -qE '\bgit\b[^|;&]*\bcommit\b' || exit 0

[ -n "${REPO_ROOT}" ] || deny "pre-commit-guard.sh cannot resolve its own repository root; refusing rather than guessing."

# Most specific source first: explicit `git -C <dir>`, a leading `cd <dir>`, the session cwd.
target_dir=""
explicit_c="$(printf '%s' "${command_line}" \
    | grep -oE '\bgit[[:space:]]+-C[[:space:]]+[^[:space:];&|]+' | head -1 | awk '{print $3}')"
leading_cd="$(printf '%s' "${command_line}" \
    | grep -oE '^[[:space:]]*cd[[:space:]]+[^[:space:];&|]+' | head -1 | awk '{print $2}')"
session_cwd="$(printf '%s' "${payload}" | jq -r '.cwd // ""' 2>/dev/null)"

for candidate in "${explicit_c}" "${leading_cd}" "${session_cwd}"; do
    [ -n "${candidate}" ] || continue
    target_dir="${candidate/#\~/${HOME}}"
    break
done

if [ -n "${target_dir}" ] && [ -d "${target_dir}" ]; then
    target_root="$(git -C "${target_dir}" rev-parse --show-toplevel 2>/dev/null || true)"
    # A different repository has its own branch rules and its own validator.
    if [ -n "${target_root}" ] && [ "${target_root}" != "${REPO_ROOT}" ]; then
        exit 0
    fi
fi

branch="$(git -C "${REPO_ROOT}" branch --show-current 2>/dev/null || true)"
if [ "${branch}" = "main" ]; then
    deny "Direct commit on main is blocked. Create a branch first; main is reached through a pull request, which the GitHub ruleset also enforces."
fi

if findings="$("${REPO_ROOT}/scripts/validate-repo.sh" 2>&1)"; then
    exit 0
fi

deny "$(printf 'validate-repo.sh reports findings, so the commit was blocked. Fix these, then commit again.\n\n%s' \
    "$(printf '%s' "${findings}" | grep -E '^  |^FAIL' | grep -v 'SKIP:' | head -20)")"
