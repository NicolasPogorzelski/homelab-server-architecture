#!/usr/bin/env bash
# Writing checks that a pattern can decide, for the Markdown files given as arguments.
# validate-repo.sh runs it over the repository; the PostToolUse hook prose-lint-hook.sh runs it
# on each file as it is written, so a finding is fixed before the diff is shown.
# Judgement cases (maxims, punchlines) are left to review: a pattern for them would misfire.
# Prints "<file>:<line>: <finding>" per hit and exits 1 if there was any.
set -uo pipefail

hits=0
for file in "$@"; do
    [[ -f "${file}" ]] || continue
    case "${file}" in
        # Where the rules and templates themselves are written.
        *CLAUDE.md|*.claude/*|*docs/CONVENTIONS.md) continue ;;
    esac

    # A dated verification opens with "Verified <date>:", not with the bare date.
    while IFS= read -r m; do
        echo "${file}:${m%%:*}: Verification opens with a bare date; write 'Verified <date>: ...'"
        hits=$((hits + 1))
    done < <(grep -nP '^\*\*Verification\.\*\*\s+20\d\d-\d\d-\d\d\b' "${file}" || true)

    # Self-narration: the text describing itself. Scope statements ("this runbook covers") pass.
    while IFS= read -r m; do
        echo "${file}:${m%%:*}: Sentence about the document itself; state the content instead"
        hits=$((hits + 1))
    done < <(grep -niP '\bthis (record|document|entry|section) (proposes|exists|explains|describes|summari[sz]es|aims|tries)\b' "${file}" || true)
done

(( hits == 0 ))
