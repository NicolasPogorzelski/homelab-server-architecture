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
# Known cost of matching that broadly, and it is accepted rather than fixed: any
# command that merely mentions both words is treated as a commit. A branch whose
# name contains "commit" cannot be created from main without the guard refusing.
# Narrowing the pattern to avoid that would reintroduce the compound-command hole
# it was widened to close, and a false refusal costs one rename.
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

# The payload is read once and reused: stdin cannot be consumed twice, and the
# repository check below needs a second field out of it.
payload="$(cat)"
command_line="$(printf '%s' "${payload}" | jq -r '.tool_input.command // ""' 2>/dev/null)"

# Not a commit: say nothing, let the call through.
printf '%s' "${command_line}" | grep -qE '\bgit\b[^|;&]*\bcommit\b' || exit 0

# Which repository does this command actually touch?
#
# Until 2026-09-12 the guard never asked. It resolved REPO_ROOT from its own
# location and judged that repository's branch, whatever the command was working
# on. Both directions were wrong and both were observed on one day: a commit to
# the sister repository was let through in the morning because this one sat on a
# feature branch, and refused in the afternoon because this one sat on main.
# Neither verdict had anything to do with the commit being made.
#
# The under-blocking direction is the one that matters. A guard that can be
# switched off by the state of an unrelated checkout is not a guard, and the
# second half of this hook is worse in that case than merely absent: it runs this
# repository's validator against a commit in a repository that has its own.
#
# Three sources, most specific first: an explicit `git -C <dir>`, which retargets
# without changing directory; a leading `cd <dir>` in a compound command, which is
# how commits to another repository are normally written here; and otherwise the
# session's own working directory out of the hook payload.
#
# Deliberately fails safe. The guard steps aside only when it can resolve a
# directory to a git worktree that is demonstrably a different repository.
# Anything it cannot resolve is treated as this one, because over-blocking costs a
# retry and under-blocking costs the thing this hook exists to prevent.
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
    if [ -n "${target_root}" ] && [ "${target_root}" != "${REPO_ROOT}" ]; then
        # A different repository, with its own branch conventions and its own
        # validator. Neither of the checks below can speak for it.
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
