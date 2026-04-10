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
# Check 5: Runbook contract — required sections
# =============================================================================
# Contract from runbooks/README.md:
# Preconditions, Commands/steps, Verification, Failure modes
echo "Check 5: runbook contract sections"

RUNBOOK_SECTIONS=("Precondition" "Verification" "Failure")

if [[ -d "${REPO_ROOT}/runbooks" ]]; then
    while read -r file; do
        # skip README.md (index file, not a runbook)
        [[ "$(basename "${file}")" == "README.md" ]] && continue
        for section in "${RUNBOOK_SECTIONS[@]}"; do
            if ! grep -qi "${section}" "${file}"; then
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
# Allowed top-level: docs/ docker/ snippets/ runbooks/ scripts/ README.md .gitignore
echo "Check 12: files outside directory structure"

while read -r file; do
    rel="${file#${REPO_ROOT}/}"
    case "${rel}" in
        docs|docker|snippets|runbooks|scripts) continue ;;
        docs/*|docker/*|snippets/*|runbooks/*|scripts/*) continue ;;
        README.md|.gitignore) continue ;;
        .*) continue ;;  # hidden files managed by git
        *) echo "  Unexpected: ${rel}"
           ERRORS=$((ERRORS + 1))
           ;;
    esac
done < <(find "${REPO_ROOT}" -maxdepth 1 -not -path "${REPO_ROOT}" -not -name ".git" \( -type f -o -type d \))

# =============================================================================
# Results
# =============================================================================
echo ""
echo "=== Done ==="
echo "Checks run: 12"
if [[ "${ERRORS}" -gt 0 ]]; then
    echo "FAIL: ${ERRORS} error(s) found."
    exit 1
else
    echo "PASS: All checks passed."
    exit 0
fi
