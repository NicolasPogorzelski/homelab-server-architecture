#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ERRORS=0
ERROR_LOG="$(mktemp)"
trap 'rm -f "${ERROR_LOG}"' EXIT

echo "=== Repo Validation ==="
echo "Repo root: ${REPO_ROOT}"
echo ""

# =============================================================================
# Check 1: empty markdown files
# =============================================================================
echo "Check 1: empty markdown files"

while read -r file; do
    echo "  Empty: ${file}"
    ERRORS=$((ERRORS + 1))
done < <(find "${REPO_ROOT}" -name "*.md" -empty)

# =============================================================================
# Check 2: broken internal markdown links
# =============================================================================
# Gitignored files are skipped, the same way Check 24 skips them. A scratch file
# under .claude/ is not repository content, and its links are written for
# somewhere else - a pull-request body renders on github.com, not from that
# directory. Before 2026-08-19 such a file could fail the whole validation.
echo "Check 2: broken internal links"

while read -r mdfile; do
    rel="${mdfile#${REPO_ROOT}/}"
    git -C "${REPO_ROOT}" check-ignore -q "${rel}" 2>/dev/null && continue
    dir="$(dirname "${mdfile}")"
    { grep -oP '\]\(\K[^)]+' "${mdfile}" || true; } | while read -r link; do
        [[ "${link}" =~ ^https?:// ]] && continue
        link="${link%%#*}"
        [[ -z "${link}" ]] && continue
        if [[ ! -f "${dir}/${link}" && ! -d "${dir}/${link}" ]]; then
            echo "  Broken: ${mdfile} -> ${link}"
            echo "x" >> "${ERROR_LOG}"
        fi
    done
done < <(find "${REPO_ROOT}" -name "*.md" -type f)

# Truncate, or Check 7 counts these same entries a second time. Missing until
# 2026-08-19, and invisible until Check 2 actually found something: two broken
# links were reported as four errors.
ERRORS=$((ERRORS + $(wc -l < "${ERROR_LOG}")))
: > "${ERROR_LOG}"

# =============================================================================
# Check 3: committed .env files
# =============================================================================
echo "Check 3: committed .env files"

while read -r file; do
    echo "  Found: ${file}"
    ERRORS=$((ERRORS + 1))
done < <(find "${REPO_ROOT}" -not -path "*/.git/*" \( -name ".env" -o -name ".env.*" \) -not -name ".env.example")

# =============================================================================
# Check 4: Access Model section in service docs
# =============================================================================
# Rule from tailscale-acl.md:
# "Every docs/services/*.md file must include an Access Model (Zero Trust) section"
echo "Check 4: Access Model section in service docs"

if [[ -d "${REPO_ROOT}/docs/services" ]]; then
    while read -r file; do
        if ! grep -q "## Access Model" "${file}"; then
            echo "  Missing 'Access Model' section: ${file}"
            ERRORS=$((ERRORS + 1))
        fi
    done < <(find "${REPO_ROOT}/docs/services" -name "*.md" -type f)
fi

# =============================================================================
# Check 5: Runbook contract - required sections
# =============================================================================
# Contract from runbooks/README.md:
# Preconditions, Commands/steps, Verification, Failure modes, Rollback / abort
#
# Rollback became mandatory on 2026-08-15. The contract had listed it as "only if applicable"
# since the beginning, and the result was that it appeared in 2 runbooks out of 13 - present in
# exactly the two written most recently, when the danger was fresh. An optional section is a
# preference, not a contract.
#
# "Not applicable" remains a legitimate answer and must be *written down with its reason*. A
# read-only procedure genuinely has nothing to undo, but a document with no such section cannot
# be distinguished from one where nobody thought about it - and that difference is the whole
# value of asking.
echo "Check 5: runbook contract sections"

RUNBOOK_SECTIONS=("Precondition" "Verification" "Failure" "Rollback")

if [[ -d "${REPO_ROOT}/runbooks" ]]; then
    while read -r file; do
        # skip README.md (index file, not a runbook)
        [[ "$(basename "${file}")" == "README.md" ]] && continue
        for section in "${RUNBOOK_SECTIONS[@]}"; do
            if ! grep -qiE "^##[[:space:]].*${section}" "${file}"; then
                echo "  Missing '${section}' section: ${file}"
                ERRORS=$((ERRORS + 1))
            fi
        done
    done < <(find "${REPO_ROOT}/runbooks" -name "*.md" -type f)
fi

# =============================================================================
# Check 6: Failure Impact section in node docs
# =============================================================================
echo "Check 6: Failure Impact in node docs"

if [[ -d "${REPO_ROOT}/docs/nodes" ]]; then
    while read -r file; do
        if ! grep -q "## Failure Impact" "${file}"; then
            echo "  Missing 'Failure Impact' section: ${file}"
            ERRORS=$((ERRORS + 1))
        fi
    done < <(find "${REPO_ROOT}/docs/nodes" -name "*.md" -type f)
fi

# =============================================================================
# Check 13: Configuration Management section in node docs
# =============================================================================
echo "Check 13: Configuration Management in node docs"

if [[ -d "${REPO_ROOT}/docs/nodes" ]]; then
    while read -r file; do
        # lxc250 is the Ansible control node - excluded from inventory, has ## Ansible Setup instead
        [[ "$(basename "${file}")" == "lxc250.md" ]] && continue
        if ! grep -q "## Configuration Management" "${file}"; then
            echo "  Missing 'Configuration Management' section: ${file}"
            ERRORS=$((ERRORS + 1))
        fi
    done < <(find "${REPO_ROOT}/docs/nodes" -name "*.md" -type f)
fi

# =============================================================================
# Check 7: no plain Tailscale IPs (100.x.y.z) in docs
# =============================================================================
# Legitimate placeholder: <tailscale-ip-...>
# Violation: bare 100.x.y.z addresses
echo "Check 7: no plain Tailscale IPs"

while read -r mdfile; do
    { grep -nP '(?<!<tailscale-ip[->])100\.\d{1,3}\.\d{1,3}\.\d{1,3}' "${mdfile}" || true; } | while read -r match; do
        echo "  Unsanitized IP: ${mdfile}:${match}"
        echo "x" >> "${ERROR_LOG}"
    done
done < <(find "${REPO_ROOT}" -not -path "*/.git/*" -name "*.md" -type f)

# reset and recount error log
ERRORS=$((ERRORS + $(wc -l < "${ERROR_LOG}")))
: > "${ERROR_LOG}"

# =============================================================================
# Check 14: no plain RFC-1918 LAN IPs in docs
# =============================================================================
# Legitimate placeholder: <lan-ip-...>
# Covers: 192.168.x.x, 10.x.x.x, 172.16-31.x.x
# File types: .md, .yml, .yaml, .sh
echo "Check 14: no plain LAN IPs"

while read -r file; do
    { grep -nP '\b(192\.168|10\.\d{1,3}|172\.(?:1[6-9]|2[0-9]|3[01]))\.\d{1,3}\.\d{1,3}\b' "${file}" || true; } | while read -r match; do
        echo "  Unsanitized LAN IP: ${file}:${match}"
        echo "x" >> "${ERROR_LOG}"
    done
done < <(find "${REPO_ROOT}" -not -path "*/.git/*" \( -name "*.md" -o -name "*.yml" -o -name "*.yaml" -o -name "*.sh" \) -type f)

# reset and recount error log
ERRORS=$((ERRORS + $(wc -l < "${ERROR_LOG}")))
: > "${ERROR_LOG}"

# =============================================================================
# Check 8: no plain tailnet IDs in docs
# =============================================================================
# Legitimate placeholder: <tailnet-id>
# Violation: actual tailnet domain like abc123.ts.net (without placeholder brackets)
echo "Check 8: no plain tailnet IDs"

while read -r mdfile; do
    { grep -nP '(?<!<)[a-z0-9-]+\.ts\.net' "${mdfile}" | grep -vP '<tailnet-id>' || true; } | while read -r match; do
        echo "  Unsanitized tailnet ID: ${mdfile}:${match}"
        echo "x" >> "${ERROR_LOG}"
    done
done < <(find "${REPO_ROOT}" -not -path "*/.git/*" -name "*.md" -type f)

ERRORS=$((ERRORS + $(wc -l < "${ERROR_LOG}")))
: > "${ERROR_LOG}"

# =============================================================================
# Check 9: no private keys or certificates in repo
# =============================================================================
echo "Check 9: no private keys or certificates"

while read -r file; do
    echo "  Found: ${file}"
    ERRORS=$((ERRORS + 1))
done < <(find "${REPO_ROOT}" -not -path "*/.git/*" \( -name "*.pem" -o -name "*.key" -o -name "*.crt" -o -name "*.p12" -o -name "*.pfx" \) -type f)

# =============================================================================
# Check 10: .env.example for each docker-compose directory
# =============================================================================
echo "Check 10: .env.example per compose directory"

if [[ -d "${REPO_ROOT}/docker" ]]; then
    while read -r composefile; do
        composedir="$(dirname "${composefile}")"
        if [[ ! -f "${composedir}/.env.example" ]]; then
            echo "  Missing .env.example: ${composedir}/"
            ERRORS=$((ERRORS + 1))
        fi
    done < <(find "${REPO_ROOT}/docker" -name "docker-compose.yml" -type f)
fi

# =============================================================================
# Check 11: no duplicate headings in markdown files
# =============================================================================
echo "Check 11: duplicate markdown headings"

while read -r mdfile; do
    { grep -nP '^## ' "${mdfile}" || true; } | \
        sed 's/^[0-9]*://' | \
        sort | uniq -d | while read -r dup; do
            echo "  Duplicate heading in ${mdfile}: ${dup}"
            echo "x" >> "${ERROR_LOG}"
        done
done < <(find "${REPO_ROOT}" -name "*.md" -type f)

ERRORS=$((ERRORS + $(wc -l < "${ERROR_LOG}")))
: > "${ERROR_LOG}"

# =============================================================================
# Check 12: no files outside defined directory structure
# =============================================================================
# Allowed top-level: docs/ docker/ snippets/ runbooks/ scripts/ ansible/ terraform/
#                    README.md CLAUDE.md LICENSE .gitignore
# LICENSE must sit in the repository root: GitHub's license detection only looks there, so moving
# it into a subdirectory would silently drop the license badge and the API field. SECURITY.md is
# deliberately *not* listed - it lives in .github/, which this check skips as a hidden entry, and
# GitHub reads it from there just as well.
echo "Check 12: files outside directory structure"

while read -r file; do
    rel="${file#${REPO_ROOT}/}"
    case "${rel}" in
        docs|docker|snippets|runbooks|scripts|ansible|terraform) continue ;;
        docs/*|docker/*|snippets/*|runbooks/*|scripts/*|ansible/*|terraform/*) continue ;;
        README.md|CLAUDE.md|LICENSE|.gitignore) continue ;;
        .*) continue ;;  # hidden files managed by git
        *)
           if git -C "${REPO_ROOT}" check-ignore -q "${rel}" 2>/dev/null; then
               continue
           fi
           echo "  Unexpected: ${rel}"
           ERRORS=$((ERRORS + 1))
           ;;
    esac
done < <(find "${REPO_ROOT}" -maxdepth 1 -not -path "${REPO_ROOT}" -not -name ".git" \( -type f -o -type d \))

# =============================================================================
# Check 15: no leftover git merge conflict markers
# =============================================================================
# A botched merge can leave `<<<<<<<`, `=======`, or `>>>>>>>` lines committed.
# These are never legitimate content in this repo's tracked files.
echo "Check 15: no merge conflict markers"

while read -r file; do
    { grep -nE '^(<<<<<<< |=======$|>>>>>>> )' "${file}" || true; } | while read -r match; do
        echo "  Merge conflict marker: ${file}:${match}"
        echo "x" >> "${ERROR_LOG}"
    done
done < <(find "${REPO_ROOT}" -not -path "*/.git/*" \( -name "*.md" -o -name "*.yml" -o -name "*.yaml" -o -name "*.sh" -o -name "*.conf" -o -name "*.j2" \) -type f)

ERRORS=$((ERRORS + $(wc -l < "${ERROR_LOG}")))
: > "${ERROR_LOG}"

# =============================================================================
# Check 16: ansible-lint on staged Ansible changes
# =============================================================================
# Structural checks 1-15 never look inside Ansible files, so three commits went
# out green locally on 2026-07-10 and turned CI red. This closes that gap at the
# pre-commit hook, not in CI: .github/workflows/ansible-lint.yml already runs a
# version-pinned lint on every push. Consequently this check SKIPs under CI --
# actions/checkout leaves a clean tree, so there is no diff to test.
#
# ansible-lint exits 2 on findings, which `set -e` would turn into a silent
# abort before the output is printed. The call is therefore guarded.
echo "Check 16: ansible-lint (production profile)"

# Staged files first: the PreToolUse hook fires while `git commit` holds an
# index. `git commit -a` stages at commit time instead, leaving --cached empty,
# so fall back to the working tree. A clean tree (CI) yields neither.
changed="$(git -C "${REPO_ROOT}" diff --cached --name-only 2>/dev/null || true)"
if [[ -z "${changed}" ]]; then
    changed="$(git -C "${REPO_ROOT}" diff --name-only HEAD 2>/dev/null || true)"
fi

if ! command -v ansible-lint >/dev/null 2>&1; then
    echo "  SKIP: ansible-lint not in PATH"
elif ! grep -q '^ansible/' <<< "${changed}"; then
    echo "  SKIP: no changes under ansible/"
else
    # ansible.cfg sets vault_password_file = ~/.vault_pass, and that file exists
    # by design only on the control node (lxc250) -- it is the single copy this
    # repo tracks as an irreversible-loss risk. Without it, the per-playbook
    # `ansible-playbook --syntax-check` that ansible-lint runs aborts with an
    # internal-error for EVERY playbook, and this check reports dozens of
    # failures that have nothing to do with the diff. That blocked all Ansible
    # commits from the admin workstation -- the machine this repo says feature
    # work belongs on -- and it did so by conflating "cannot run" with "found
    # problems".
    #
    # A throwaway password is sufficient and is what CI already does
    # (.github/workflows/ansible-lint.yml): --syntax-check parses the committed
    # !vault vars but never decrypts them. Deliberately NOT written to
    # ~/.vault_pass: a dummy sitting at the real path would later be mistaken
    # for the real secret. Skipping instead would reopen the very gap this check
    # exists to close, silently.
    vault_pw_file=""
    if [[ ! -r "${HOME}/.vault_pass" ]]; then
        vault_pw_file="$(mktemp)"
        echo 'syntax-check-only' > "${vault_pw_file}"
        export ANSIBLE_VAULT_PASSWORD_FILE="${vault_pw_file}"
    fi

    # --nocolor: the output is captured, not written to a TTY, and rich would
    # otherwise emit ANSI colour and OSC-8 hyperlink escapes into the hook log.
    lint_output="$(cd "${REPO_ROOT}/ansible" && ansible-lint --nocolor . 2>&1)" && lint_rc=0 || lint_rc=$?

    if [[ -n "${vault_pw_file}" ]]; then
        rm -f "${vault_pw_file}"
        unset ANSIBLE_VAULT_PASSWORD_FILE
    fi

    if [[ "${lint_rc}" -ne 0 ]]; then
        echo "${lint_output}" | sed 's/^/  /'
        echo "  ansible-lint failed (exit ${lint_rc})"
        ERRORS=$((ERRORS + 1))
    fi
fi

# =============================================================================
# Check 17: private *.local.md legend files must never be tracked
# =============================================================================
# The sanitization legend maps public placeholders back to real capacities,
# device paths and disk labels. It is gitignored on purpose; a single tracked
# copy would re-leak everything the history rewrite removed.
echo "Check 17: private .local.md files not tracked"

while read -r file; do
    rel="${file#${REPO_ROOT}/}"
    if git -C "${REPO_ROOT}" ls-files --error-unmatch "${rel}" >/dev/null 2>&1; then
        echo "  Tracked private file (must stay gitignored): ${rel}"
        ERRORS=$((ERRORS + 1))
    fi
done < <(find "${REPO_ROOT}" -not -path "*/.git/*" -name "*.local.md" -type f)

# =============================================================================
# Check 18: no size-encoding disk labels (auxNtb -> use aux-diskN)
# =============================================================================
# Labels that encode a disk's capacity in the name were sanitized out of the
# public history; the sanitized form is `aux-diskN`. Gitignored files (the
# private legend, which legitimately holds the real labels) are skipped.
echo "Check 18: no size-encoding disk labels (auxNtb)"

while read -r file; do
    rel="${file#${REPO_ROOT}/}"
    git -C "${REPO_ROOT}" check-ignore -q "${rel}" 2>/dev/null && continue
    { grep -niE 'aux[0-9]+tb' "${file}" || true; } | while read -r match; do
        echo "  Size-encoding disk label: ${file}:${match}"
        echo "x" >> "${ERROR_LOG}"
    done
done < <(find "${REPO_ROOT}" -not -path "*/.git/*" \( -name "*.md" -o -name "*.yml" -o -name "*.yaml" -o -name "*.sh" -o -name "*.conf" -o -name "*.j2" \) -type f)

ERRORS=$((ERRORS + $(wc -l < "${ERROR_LOG}")))
: > "${ERROR_LOG}"

# =============================================================================
# Check 19: plain-ASCII punctuation only
# =============================================================================
# Documentation here is read in terminals, greps and diffs as often as in a
# browser. Typographic punctuation (em dash, en dash, curly quotes, ellipsis,
# arrows, multiplication sign, emoji) renders inconsistently across terminals and
# fonts, is awkward to type, and is easy to search for only if you already know
# which of the several look-alike codepoints was used. Config files, scripts and
# unit templates in this repository are ASCII anyway, so the documentation
# follows the same rule rather than keeping a second convention.
#
# Two exceptions, both deliberate:
#   U+2500-U+257F  box-drawing characters, used in the ASCII architecture
#                  diagrams, where they are the conventional tool and not a
#                  stylistic flourish
#   U+00A7         the section sign, used when citing a document section
#
# The check deliberately reports the offending character and its position rather
# than only the file, because a single stray character in a 400-line document is
# otherwise a search problem. Gitignored files are skipped.
echo "Check 19: plain-ASCII punctuation"

while read -r file; do
    rel="${file#${REPO_ROOT}/}"
    git -C "${REPO_ROOT}" check-ignore -q "${rel}" 2>/dev/null && continue
    { grep -noP '(?![\x{2500}-\x{257F}\x{00A7}])[^\x00-\x7F]' "${file}" || true; } | while read -r match; do
        echo "  Non-ASCII punctuation: ${rel}:${match}"
        echo "x" >> "${ERROR_LOG}"
    done
done < <(find "${REPO_ROOT}" -not -path "*/.git/*" -type f \
              \( -name "*.md" -o -name "*.yml" -o -name "*.yaml" -o -name "*.sh" \
                 -o -name "*.j2" -o -name "*.conf" -o -name "*.py" -o -name "*.json" \
                 -o -name "*.example" \))

ERRORS=$((ERRORS + $(wc -l < "${ERROR_LOG}")))
: > "${ERROR_LOG}"

# Check 20: bold used as a label, not as mid-sentence emphasis
# =============================================================================
# CLAUDE.md has required this since 2026-08-15 and nothing enforced it, so it
# drifted immediately: on 2026-08-16 a review found bold emphasis scattered
# through freshly written documents. Emphasis inside a running sentence is the
# habit this repository is trying not to have - it reads as a machine deciding
# which words matter for you, and after a few paragraphs it stops carrying any
# signal at all.
#
# Legitimate uses start a line or a list item ("- **Precondition:** ..."), sit in
# a table cell, or follow a heading marker. All of those are preceded by start of
# line, "- ", "| " or "# ", none of which match the pattern below, which requires
# a word character or punctuation immediately before the opening marker.
#
# Bold spanning a line break is not detected. That is accepted: the check is a
# net for the common case, not a markdown parser.
echo "Check 20: bold as label, not mid-sentence emphasis"

while read -r file; do
    rel="${file#${REPO_ROOT}/}"
    git -C "${REPO_ROOT}" check-ignore -q "${rel}" 2>/dev/null && continue
    case "${rel}" in CLAUDE.md) continue ;; esac
    { grep -nE "[a-zA-Z0-9,;:)] \*\*[^*]+\*\*" "${file}" || true; } | while read -r match; do
        echo "  Mid-sentence bold: ${rel}:${match%%:*}"
        echo "x" >> "${ERROR_LOG}"
    done
done < <(find "${REPO_ROOT}" -not -path "*/.git/*" -type f -name "*.md")

ERRORS=$((ERRORS + $(wc -l < "${ERROR_LOG}")))
: > "${ERROR_LOG}"

# Check 21: repository content is English
# =============================================================================
# Added 2026-08-16, after a pull request description was drafted in German
# because the conversation happened to be in German. The repository is public and
# read by people who do not speak it, and every one of its ~17,600 lines was
# already English - the rule simply had never been written down or checked.
#
# The word list is deliberately short and contains only words with no English
# homograph, so a false positive means real German text rather than an unlucky
# identifier. Common articles (der, die, das) are excluded for that reason.
echo "Check 21: repository content is English"

while read -r file; do
    rel="${file#${REPO_ROOT}/}"
    git -C "${REPO_ROOT}" check-ignore -q "${rel}" 2>/dev/null && continue
    # This script carries the word list itself, so it would always match.
    case "${rel}" in scripts/validate-repo.sh) continue ;; esac
    { grep -nwiE "nicht|wurde|wurden|werden|damit|deshalb|sondern|jedoch|bereits|zwischen" "${file}" || true; } | while read -r match; do
        echo "  German text: ${rel}:${match%%:*}"
        echo "x" >> "${ERROR_LOG}"
    done
done < <(find "${REPO_ROOT}" -not -path "*/.git/*" -type f \
              \( -name "*.md" -o -name "*.yml" -o -name "*.yaml" -o -name "*.sh" \
                 -o -name "*.j2" \))

ERRORS=$((ERRORS + $(wc -l < "${ERROR_LOG}")))
: > "${ERROR_LOG}"

# =============================================================================
# Check 22: no personal media library counts
# =============================================================================
# Added 2026-08-17, after a verification step recorded the exact number of films
# in the Jellyfin library - in a changelog entry and in a pull request description,
# both public. The count proves nothing operational: "the library enumerates its
# full expected contents" is the same evidence without describing what the owner
# of this repository watches, reads and listens to.
#
# The other sanitization checks all guard infrastructure (addresses, keys, disk
# labels). This one guards the person, which is a different category and is why it
# gets its own check rather than an extra pattern in Check 14.
#
# Aggregate counts that scale with the collection - objects swept, files compared -
# are covered by Check 23 rather than here, because they arrive in a different
# grammatical shape. If a number would let a reader infer the size of a personal
# library, it does not belong in this repository.
echo "Check 22: no personal media library counts"

while read -r file; do
    rel="${file#${REPO_ROOT}/}"
    git -C "${REPO_ROOT}" check-ignore -q "${rel}" 2>/dev/null && continue
    # This script carries the pattern itself.
    case "${rel}" in scripts/validate-repo.sh) continue ;; esac
    # "series" is also Prometheus vocabulary ("old expression 21 series"), so lines
    # carrying monitoring terms are dropped rather than the word being given up -
    # a television count is exactly the kind of hit this check exists for.
    { grep -nEi "[0-9][0-9,.]*[[:space:]]+(films?|movies|series|seasons?|episodes?|authors?|audiobooks?|ebooks?|albums?|tracks?|titles?)\b" "${file}" \
        | grep -viE "expression|prometheus|promql|metric|series per node|time series" || true; } | while read -r match; do
        echo "  Media library count: ${rel}:${match%%:*}"
        echo "x" >> "${ERROR_LOG}"
    done
done < <(find "${REPO_ROOT}" -not -path "*/.git/*" -type f \
              \( -name "*.md" -o -name "*.yml" -o -name "*.yaml" -o -name "*.sh" \
                 -o -name "*.j2" \))

ERRORS=$((ERRORS + $(wc -l < "${ERROR_LOG}")))
: > "${ERROR_LOG}"

# =============================================================================
# Check 23: no measured fill level for the archive pool
# =============================================================================
# Added 2026-08-17, one commit after Check 22, because Check 22 did not catch the
# next occurrence. How full the media pool is says how much content it holds, which
# is the same disclosure as counting the files - only in a different unit, so a
# check written around media nouns never sees it.
#
# The discriminator is the decimal point. A threshold is a round number somebody
# chose ("15% free" in the DiskSpaceCritical rule); a fill level is a precise number
# somebody measured. Requiring a fraction keeps the configured thresholds legal and
# still catches the measurement.
#
# Scoped to lines that also name the archive pool, deliberately. The LVM thin pool
# on the host carries decimal percentages throughout the documentation and they are
# infrastructure, not content - flagging twenty of those would make this check the
# kind of always-red signal the alert rules in this repository are written to avoid.
#
# The occurrence that prompted it is worth stating plainly: it was not in the
# original documentation but in the write-up describing the removal, which quoted
# both forms of the figure in order to explain them. A text about deleting a value
# is one more place the value appears.
echo "Check 23: no measured fill level for the archive pool"

while read -r file; do
    rel="${file#${REPO_ROOT}/}"
    git -C "${REPO_ROOT}" check-ignore -q "${rel}" 2>/dev/null && continue
    case "${rel}" in scripts/validate-repo.sh) continue ;; esac
    { grep -nE "mergerfs|MergerFS|archive pool|fill level" "${file}" \
        | grep -E "[0-9]+\.[0-9]+[[:space:]]*%" || true; } | while read -r match; do
        echo "  Archive fill level: ${rel}:${match%%:*}"
        echo "x" >> "${ERROR_LOG}"
    done
done < <(find "${REPO_ROOT}" -not -path "*/.git/*" -type f \
              \( -name "*.md" -o -name "*.yml" -o -name "*.yaml" -o -name "*.sh" \
                 -o -name "*.j2" \))

ERRORS=$((ERRORS + $(wc -l < "${ERROR_LOG}")))
: > "${ERROR_LOG}"

# =============================================================================
# Check 24: balanced markdown code fences
# =============================================================================
# Added 2026-08-17. docs/architecture/exposure-diagram.md was missing its closing
# ``` and had been that way since 2026-04-07 - four months during which GitHub
# rendered the Mermaid source as plain text on a page the README advertises as a
# diagram. Nothing caught it: Check 1 sees a non-empty file, Check 2 sees valid
# links, and no check has ever looked at markdown structure.
#
# The test is deliberately the crudest one that works: an opening and a closing
# fence are the same token, so a correct file has an even number of lines
# starting with ```. That makes the check incapable of a false negative on the
# defect it exists for, and it needs no parser.
#
# Known blind spot, accepted: a fence line quoted *inside* another fenced block
# flips the parity and would be reported. That is rare here and loud when it
# happens - the alternative is tracking open/closed state, which turns a
# four-line check into something that itself needs tests. Documentation about
# markdown syntax should indent its examples rather than fence them.
echo "Check 24: balanced markdown code fences"

while read -r file; do
    rel="${file#${REPO_ROOT}/}"
    git -C "${REPO_ROOT}" check-ignore -q "${rel}" 2>/dev/null && continue
    fences="$(grep -c '^```' "${file}" || true)"
    if (( fences % 2 != 0 )); then
        echo "  Unbalanced code fence (${fences} found): ${rel}"
        echo "x" >> "${ERROR_LOG}"
    fi
done < <(find "${REPO_ROOT}" -not -path "*/.git/*" -type f -name "*.md")

ERRORS=$((ERRORS + $(wc -l < "${ERROR_LOG}")))
: > "${ERROR_LOG}"

# =============================================================================
# Check 25: counted claims in the README match what is countable
# =============================================================================
# Added 2026-08-19, after the README had said "Thirteen procedures" for four
# days while runbooks/ held fourteen - mariadb-backup.md arrived on 2026-08-15
# and the prose was never recounted. Same class as the seven hand-counted
# numbers the 2026-08-17 audit found across the documentation: a number written
# into prose has no owner, and only one possible future.
#
# The repository's usual answer is to delete such a number where a table already
# carries it. These four are kept because they tell a reader the size of the
# thing, so they are machine-checked instead. Nothing is hardcoded: both sides
# are computed at run time, so adding a runbook or a role fails this check until
# the sentence is updated. That is the intended cost.
#
# Deliberately not covered: the node counts in the opening line ("ten guests",
# "nine of eleven nodes"). They cannot be derived from this repository at all -
# the real inventory is gitignored - so a check could only compare prose against
# hosts.yml.example, a file that can drift from the fleet just as easily.
#
# A missing claim is an error, not a pass. Deleting the sentence therefore fails
# this check until its entry below is removed as well. That friction is the
# point: a guard whose pattern silently stops matching is the failure class this
# platform keeps finding in its own monitoring, and it costs one deliberate edit
# to retire a claim on purpose.
#
# Verified both ways when written: a wrong count, a wrong role number and a
# deleted claim each produce a named failure, and the clean tree passes.
echo "Check 25: counted claims match the repository"

README_FILE="${REPO_ROOT}/README.md"
SELF="${REPO_ROOT}/scripts/validate-repo.sh"

word_to_number() {
    case "${1,,}" in
        ten) echo 10 ;;      eleven) echo 11 ;;    twelve) echo 12 ;;
        thirteen) echo 13 ;; fourteen) echo 14 ;;  fifteen) echo 15 ;;
        sixteen) echo 16 ;;  seventeen) echo 17 ;; eighteen) echo 18 ;;
        nineteen) echo 19 ;; twenty) echo 20 ;;
        *) echo "${1}" ;;
    esac
}

compare_claim() {
    local label="$1" claimed="$2" actual="$3"
    if [[ -z "${claimed}" ]]; then
        echo "  Claim not found in README: ${label}"
        echo "x" >> "${ERROR_LOG}"
    elif [[ "${claimed}" != "${actual}" ]]; then
        echo "  ${label}: README says ${claimed}, repository has ${actual}"
        echo "x" >> "${ERROR_LOG}"
    fi
}

runbooks_actual="$(find "${REPO_ROOT}/runbooks" -name "*.md" ! -name "README.md" | wc -l)"
roles_actual="$(find "${REPO_ROOT}/ansible/roles" -mindepth 1 -maxdepth 1 -type d | wc -l)"
playbooks_actual="$(find "${REPO_ROOT}/ansible/playbooks" -maxdepth 1 -name "*.yml" | wc -l)"
checks_actual="$(grep -cE '^echo "Check [0-9]+' "${SELF}" || true)"

runbooks_prose="$(word_to_number "$({ grep -oP '^\K\w+(?= procedures under the same contract)' "${README_FILE}" || true; })")"
runbooks_list="$(word_to_number "$({ grep -oP '<summary>All \K\w+(?= runbooks</summary>)' "${README_FILE}" || true; })")"
playbooks_claim="$({ grep -oP 'Roles\]\(ansible/roles/\) - \K[0-9]+' "${README_FILE}" || true; })"
roles_claim="$({ grep -oP 'Roles\]\(ansible/roles/\) - [0-9]+ and \K[0-9]+' "${README_FILE}" || true; })"
checks_claim="$({ grep -oP 'validate-repo\.sh\) - \K[0-9]+(?= structural checks)' "${README_FILE}" || true; })"

compare_claim "runbook count (section intro)" "${runbooks_prose}" "${runbooks_actual}"
compare_claim "runbook count (list summary)" "${runbooks_list}" "${runbooks_actual}"
compare_claim "playbook count" "${playbooks_claim}" "${playbooks_actual}"
compare_claim "role count" "${roles_claim}" "${roles_actual}"
compare_claim "validator check count" "${checks_claim}" "${checks_actual}"

ERRORS=$((ERRORS + $(wc -l < "${ERROR_LOG}")))
: > "${ERROR_LOG}"

# =============================================================================
# Check 26: every document is reachable from an index
# =============================================================================
# Added 2026-08-19. The 2026-08-17 audit found 26 documents that no index linked
# to, including the ISO mapping, the data classification, the remediation plan,
# both incident write-ups, four of eight decision records and twelve of the
# runbooks. They were found by hand, one at a time. For a repository whose
# stated purpose is to be read, its strongest evidence was invisible from the
# front page - and nothing would have reported that.
#
# Reachability is defined narrowly on purpose: a document counts as reachable if
# README.md or runbooks/README.md links it directly. Transitive reachability
# would be truer to how a reader navigates and would also make the check pass on
# a chain nobody can find, which is the condition this exists to prevent.
#
# Exceptions are listed with a reason and are themselves checked for existence,
# so an exception cannot outlive the file it excuses. An unjustified exception is
# how a control catalogue turns into decoration.
echo "Check 26: every document is reachable from an index"

INDEX_FILES=("README.md" "runbooks/README.md")

# Deliberately not indexed:
#   docs/platform/ansible-progress.md - per-session learning narrative, written
#   for the operator rather than for a reader of the platform. Linked from
#   CLAUDE.md, which is where the learning track is steered from.
INDEX_EXCEPTIONS=("docs/platform/ansible-progress.md")

LINKED_LIST="$(mktemp)"

for idx in "${INDEX_FILES[@]}"; do
    idx_dir="$(dirname "${REPO_ROOT}/${idx}")"
    while read -r link; do
        [[ "${link}" =~ ^https?:// ]] && continue
        link="${link%%#*}"
        [[ -z "${link}" ]] && continue
        target="$(realpath -m --relative-to="${REPO_ROOT}" "${idx_dir}/${link}" 2>/dev/null || true)"
        [[ -n "${target}" ]] && echo "${target}" >> "${LINKED_LIST}"
    done < <({ grep -oP '\]\(\K[^)]+' "${REPO_ROOT}/${idx}" || true; })
done

for ex in "${INDEX_EXCEPTIONS[@]}"; do
    if [[ ! -f "${REPO_ROOT}/${ex}" ]]; then
        echo "  Exception names a file that no longer exists: ${ex}"
        echo "x" >> "${ERROR_LOG}"
    fi
done

while read -r doc; do
    rel="${doc#${REPO_ROOT}/}"
    skip=0
    for ex in "${INDEX_EXCEPTIONS[@]}"; do
        [[ "${rel}" == "${ex}" ]] && skip=1
    done
    (( skip )) && continue
    if ! grep -qxF "${rel}" "${LINKED_LIST}"; then
        echo "  Not linked from any index: ${rel}"
        echo "x" >> "${ERROR_LOG}"
    fi
done < <(find "${REPO_ROOT}/docs" "${REPO_ROOT}/runbooks" -type f -name "*.md")

rm -f "${LINKED_LIST}"

ERRORS=$((ERRORS + $(wc -l < "${ERROR_LOG}")))
: > "${ERROR_LOG}"

# =============================================================================
# Check 27: backticked repository paths in the docs must exist
# =============================================================================
# Added 2026-08-19. Check 2 validates markdown links; nothing validated a path
# written as prose in backticks, which is how most operational references are
# written - "the script in `snippets/scripts/lxc-fstrim.sh`". Those rot silently
# on a rename, and a runbook that names a path which no longer exists fails at
# the only moment it is ever read.
#
# A reference passes if the path exists, or if git deliberately ignores it. The
# second case is the real inventory, the .env files and the deployed Prometheus
# config: named on purpose, absent on purpose, and asking git rather than
# maintaining a second list means the exemption cannot drift from .gitignore.
#
# Historical records are excluded. changelog.md and ansible-progress.md describe
# what was true on a date; a path that was correct in July stays correct in a
# July entry, and rewriting it to match today would falsify the record.
echo "Check 27: backticked repository paths exist"

PATH_HISTORY_EXCLUDED=("docs/platform/changelog.md" "docs/platform/ansible-progress.md")

while read -r mdfile; do
    rel="${mdfile#${REPO_ROOT}/}"
    skip=0
    for ex in "${PATH_HISTORY_EXCLUDED[@]}"; do
        [[ "${rel}" == "${ex}" ]] && skip=1
    done
    (( skip )) && continue
    while read -r ref; do
        [[ -z "${ref}" ]] && continue
        [[ -e "${REPO_ROOT}/${ref}" ]] && continue
        git -C "${REPO_ROOT}" check-ignore -q "${ref}" 2>/dev/null && continue
        echo "  Path does not exist: ${rel} -> ${ref}"
        echo "x" >> "${ERROR_LOG}"
    done < <({ grep -oP '`\K(snippets|ansible|scripts|docker|docs|runbooks)/[A-Za-z0-9_./-]+(?=`)' "${mdfile}" || true; } | sort -u)
done < <(find "${REPO_ROOT}/docs" "${REPO_ROOT}/runbooks" -type f -name "*.md")

ERRORS=$((ERRORS + $(wc -l < "${ERROR_LOG}")))
: > "${ERROR_LOG}"

# =============================================================================
# Check 28: every Ansible role appears in the platform documentation
# =============================================================================
# Added 2026-08-19. The role catalogue in docs/platform/ansible.md is the only
# place a reader can see what the automation actually does. A role that exists
# and is undocumented is invisible work, and the failure mode is quiet: the
# mariadb_backup role was written on 2026-08-15 to close a gap that had itself
# gone unnoticed because a category had been declared complete.
echo "Check 28: every Ansible role is documented"

if [[ -d "${REPO_ROOT}/ansible/roles" ]]; then
    while read -r roledir; do
        role="$(basename "${roledir}")"
        if ! grep -q "${role}" "${REPO_ROOT}/docs/platform/ansible.md"; then
            echo "  Role not documented in docs/platform/ansible.md: ${role}"
            echo "x" >> "${ERROR_LOG}"
        fi
    done < <(find "${REPO_ROOT}/ansible/roles" -mindepth 1 -maxdepth 1 -type d)
fi

ERRORS=$((ERRORS + $(wc -l < "${ERROR_LOG}")))
: > "${ERROR_LOG}"

# =============================================================================
# Check 29: every node document declares a tag the ACL model knows
# =============================================================================
# Added 2026-08-19. Access on this platform is decided by the Tailscale tag a
# node carries, so a node document without one describes a machine whose reach
# nobody can look up. A tag that the ACL model does not define is worse: it reads
# as policy and grants nothing, because Tailscale ACLs are deny-by-default.
#
# This is the lxc250 shape one layer up. That node fell outside `hosts: all`
# because it was in no inventory group, and `all` excludes silently rather than
# failing. Two lists that are never held against each other produce exactly this.
echo "Check 29: node documents declare a known Tailscale tag"

ACL_DOC="${REPO_ROOT}/docs/platform/tailscale-acl.md"

if [[ -d "${REPO_ROOT}/docs/nodes" && -f "${ACL_DOC}" ]]; then
    while read -r nodedoc; do
        rel="${nodedoc#${REPO_ROOT}/}"
        tag="$({ grep -oP '^- Tag: `\Ktag:[a-z0-9-]+' "${nodedoc}" || true; } | head -1)"
        if [[ -z "${tag}" ]]; then
            echo "  No '- Tag: \`tag:...\`' line: ${rel}"
            echo "x" >> "${ERROR_LOG}"
            continue
        fi
        if ! grep -q "\"${tag}\":" "${ACL_DOC}"; then
            echo "  Tag not defined in tailscale-acl.md tagOwners: ${rel} -> ${tag}"
            echo "x" >> "${ERROR_LOG}"
        fi
    done < <(find "${REPO_ROOT}/docs/nodes" -type f -name "*.md")
fi

ERRORS=$((ERRORS + $(wc -l < "${ERROR_LOG}")))
: > "${ERROR_LOG}"

# =============================================================================
# Check 30: container images carry an explicit version tag
# =============================================================================
# Added 2026-08-19. The repository pins every image; nothing made that a rule.
# An unpinned tag has two costs that only appear later: there is no rollback
# point, because "the version that worked" has no name, and the weekly Trivy
# scan then measures whatever `:latest` resolved to at scan time rather than
# what runs.
#
# Note what this cannot see. The 2026-08-17 audit measured that no stack on the
# fleet runs a pinned image - the deployed compose files differ from these. This
# check guards the repository, and closing the gap on the fleet waits on the
# aux-disk replacement that the standing hold on docker-compose-update depends on.
echo "Check 30: container images carry an explicit tag"

while read -r composefile; do
    rel="${composefile#${REPO_ROOT}/}"
    while read -r line; do
        image="$(echo "${line}" | sed -E 's/.*image:[[:space:]]*//; s/[[:space:]]*$//' | tr -d '"'"'"'')"
        [[ -z "${image}" ]] && continue
        [[ "${image}" == *'${'* ]] && continue
        if [[ "${image}" != *:* ]]; then
            echo "  Image without a tag: ${rel} -> ${image}"
            echo "x" >> "${ERROR_LOG}"
        elif [[ "${image}" == *:latest || "${image}" == *:main || "${image}" == *:master || "${image}" == *:stable ]]; then
            echo "  Image not pinned: ${rel} -> ${image}"
            echo "x" >> "${ERROR_LOG}"
        fi
    done < <({ grep -E '^\s*image:' "${composefile}" || true; })
done < <(find "${REPO_ROOT}/docker" -name "docker-compose.yml" -type f 2>/dev/null)

ERRORS=$((ERRORS + $(wc -l < "${ERROR_LOG}")))
: > "${ERROR_LOG}"

# =============================================================================
# Check 31: secrets in Ansible variables are vaulted or referenced
# =============================================================================
# Added 2026-08-19. Every secret in this repository is currently either an inline
# `!vault` value in group_vars/all/vault.yml or a `{{ }}` reference to one. That
# is a practice, and a practice survives only as long as somebody remembers it -
# this file makes the distinction between a control and an intention its whole
# subject, so the rule is enforced rather than followed.
#
# A key whose name suggests a secret must carry an encrypted value, a variable
# reference, or nothing. A literal is an error.
#
# The name has to *end* in the secret word, not merely contain it. Substring
# matching flagged `ssh_hardening_password_authentication: "no"` on its first run -
# an sshd directive, not a credential - and a rule that needs an exception for a
# correctly named variable is a rule that will need more of them. `postgres_exporter` still keeps
# its DATA_SOURCE_NAME unencrypted in an env file on lxc260 - outside this
# repository, and tracked in the remediation plan - which is exactly the kind of
# addition this check exists to stop from spreading.
echo "Check 31: secret-looking variables are not literals"

while read -r yamlfile; do
    rel="${yamlfile#${REPO_ROOT}/}"
    while read -r line; do
        value="$(echo "${line}" | sed -E 's/^[^:]*:[[:space:]]*//; s/[[:space:]]*$//')"
        [[ -z "${value}" ]] && continue
        [[ "${value}" == '!vault'* ]] && continue
        [[ "${value}" == *'{{'* ]] && continue
        [[ "${value}" == '|' || "${value}" == '>' ]] && continue
        key="$(echo "${line}" | sed -E 's/[[:space:]]*([^:]+):.*/\1/')"
        echo "  Literal value for a secret-looking key: ${rel} -> ${key}"
        echo "x" >> "${ERROR_LOG}"
    done < <({ grep -nE '^[[:space:]]*[a-z_]*(password|passwd|secret|token|api_key|secret_key|private_key)[[:space:]]*:' "${yamlfile}" | sed 's/^[0-9]*://' || true; })
done < <(find "${REPO_ROOT}/ansible" -type f \( -name "*.yml" -o -name "*.yaml" \))

ERRORS=$((ERRORS + $(wc -l < "${ERROR_LOG}")))
: > "${ERROR_LOG}"

# =============================================================================
# Check 32: an Enforced control names what enforces it
# =============================================================================
# Added 2026-08-19. security-controls.md defines Enforced as "a machine refuses
# the wrong outcome". A row claiming that without naming the machine is the
# strongest sentence in the document backed by nothing, and this repository has
# already paid for it: three rows read Enforced until 2026-08-17 while two nodes
# accepted password authentication. The audit's own conclusion was that a false
# assurance suppresses discovery more effectively than a stated gap.
#
# The test is deliberately shallow - a link or a backticked identifier - because
# it cannot judge whether the evidence is good. It can only insist that some
# evidence is offered, which is the difference between a claim and an assertion.
echo "Check 32: Enforced controls cite their evidence"

SEC_DOC="${REPO_ROOT}/docs/platform/security-controls.md"

if [[ -f "${SEC_DOC}" ]]; then
    while read -r row; do
        if ! echo "${row}" | grep -qE '\[[^]]+\]\(|`'; then
            control="$(echo "${row}" | sed -E 's/^\|[[:space:]]*([^|]+)\|.*/\1/' | sed 's/[[:space:]]*$//')"
            echo "  Enforced without evidence: ${control}"
            echo "x" >> "${ERROR_LOG}"
        fi
    done < <({ grep -E '^\|[[:space:]]*A\.[0-9.]+ .*\|[[:space:]]*Enforced[[:space:]]*\|' "${SEC_DOC}" || true; })
fi

ERRORS=$((ERRORS + $(wc -l < "${ERROR_LOG}")))
: > "${ERROR_LOG}"

# =============================================================================
# Check 33: service documents name a node that has a node document
# =============================================================================
# Added 2026-08-19. A service document that names no node describes software
# without a machine, and one that names a node with no document points at a
# machine nobody has to describe. Both are the same defect as lxc250: an entity
# that exists in one list and not in the other, where nothing holds the two
# lists against each other.
#
# The rule is deliberately weak - at least one node identifier, and every
# identifier it does use must resolve to docs/nodes/<node>.md. It does not try
# to decide which node is the primary one, because several services legitimately
# name three: the node they run on, lxc260 for their database and vm102 for
# their files.
echo "Check 33: service documents name a documented node"

if [[ -d "${REPO_ROOT}/docs/services" ]]; then
    while read -r svc; do
        rel="${svc#${REPO_ROOT}/}"
        nodes="$({ grep -ohE '\b(vm[0-9]{3}|lxc[0-9]{3})\b' "${svc}" || true; } | sort -u)"
        if [[ -z "${nodes}" ]]; then
            echo "  Service document names no node: ${rel}"
            echo "x" >> "${ERROR_LOG}"
            continue
        fi
        while read -r node; do
            [[ -z "${node}" ]] && continue
            if [[ ! -f "${REPO_ROOT}/docs/nodes/${node}.md" ]]; then
                echo "  Names a node with no node document: ${rel} -> ${node}"
                echo "x" >> "${ERROR_LOG}"
            fi
        done <<< "${nodes}"
    done < <(find "${REPO_ROOT}/docs/services" -type f -name "*.md")
fi

ERRORS=$((ERRORS + $(wc -l < "${ERROR_LOG}")))
: > "${ERROR_LOG}"

# =============================================================================
# Results
# =============================================================================
echo ""
echo "=== Done ==="
echo "Checks run: 33"
if [[ "${ERRORS}" -gt 0 ]]; then
    echo "FAIL: ${ERRORS} error(s) found."
    exit 1
else
    echo "PASS: All checks passed."
    exit 0
fi
