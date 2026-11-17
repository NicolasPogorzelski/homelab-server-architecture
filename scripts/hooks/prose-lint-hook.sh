#!/usr/bin/env bash
#
# Claude Code PostToolUse hook (registered in .claude/settings.json) for Edit and Write. Runs
# scripts/prose-lint.sh on a Markdown file of this repository right after it was written. Exit 2
# hands the findings back to the session, which fixes them before the diff is shown; the file
# is already written, so nothing is refused. Any other file passes silently.
#
# The file's own checkout is linted with its own prose-lint.sh, so a worktree of this repository
# is covered; another repository is recognised by a different common git directory.

set -uo pipefail

HOOK_COMMON="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
[[ -n "${HOOK_COMMON}" ]] || exit 0

file="$(jq -r '.tool_input.file_path // ""' 2>/dev/null)"
[[ "${file}" == *.md && -f "${file}" ]] || exit 0

dir="$(dirname "$(readlink -f "${file}")")"
file_common="$(git -C "${dir}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
[[ "$(readlink -f "${file_common:-/nonexistent}")" == "$(readlink -f "${HOOK_COMMON}")" ]] || exit 0

root="$(git -C "${dir}" rev-parse --show-toplevel)"
lint="${root}/scripts/prose-lint.sh"
[[ -x "${lint}" ]] || exit 0

if ! out="$("${lint}" "$(readlink -f "${file}")")"; then
    printf 'prose-lint found writing that the conventions refuse:\n%s\n' \
        "$(sed "s|^$(readlink -f "${root}")/||" <<< "${out}")" >&2
    exit 2
fi
exit 0
