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
echo "Check 2: broken internal links"

while read -r mdfile; do
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

ERRORS=$((ERRORS + $(wc -l < "${ERROR_LOG}")))

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
# Results
# =============================================================================
echo ""
echo "=== Done ==="
echo "Checks run: 21"
if [[ "${ERRORS}" -gt 0 ]]; then
    echo "FAIL: ${ERRORS} error(s) found."
    exit 1
else
    echo "PASS: All checks passed."
    exit 0
fi
