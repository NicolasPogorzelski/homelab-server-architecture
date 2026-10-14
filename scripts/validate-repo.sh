#!/usr/bin/env bash
# Repository validator. Run before every commit (CI runs it on every push and pull request).
# Each check prints its name, lists findings, and adds them to the error count; the script exits 1
# if any check found something. The conventions it enforces are in docs/CONVENTIONS.md.
#
# Files ignored by git are skipped: a pre-commit gate answers for what a commit can contain, and CI
# checks out a clean tree in which ignored files do not exist.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="${REPO_ROOT}/scripts/validate-repo.sh"
ERRORS=0
ERROR_LOG="$(mktemp)"
trap 'rm -f "${ERROR_LOG}"' EXIT

echo "=== Repo Validation ==="
echo "Repo root: ${REPO_ROOT}"
echo ""

# Findings inside pipelines run in subshells, so they are appended to ERROR_LOG and counted here.
flush_errors() {
    ERRORS=$((ERRORS + $(wc -l < "${ERROR_LOG}")))
    : > "${ERROR_LOG}"
}

fail() {
    echo "  $*"
    echo "x" >> "${ERROR_LOG}"
}

ignored() {
    git -C "${REPO_ROOT}" check-ignore -q "$1" 2>/dev/null
}

# Tracked and untracked-but-not-ignored files, relative to the repository root.
repo_files() {
    git -C "${REPO_ROOT}" ls-files --cached --others --exclude-standard "$@"
}

md_files() {
    repo_files -- '*.md' | while read -r f; do [[ -f "${REPO_ROOT}/${f}" ]] && echo "${f}"; done
}

text_files() {
    repo_files | grep -E '\.(md|ya?ml|sh|j2|conf|py|json|example|cfg|nft|service|timer|container)$' \
        | while read -r f; do [[ -f "${REPO_ROOT}/${f}" ]] && echo "${f}"; done
}

# =============================================================================
# Check 1: empty markdown files
# =============================================================================
echo "Check 1: empty markdown files"

while read -r rel; do
    [[ -s "${REPO_ROOT}/${rel}" ]] || fail "Empty: ${rel}"
done < <(md_files)
flush_errors

# =============================================================================
# Check 2: internal links point at files that exist in the repository
# =============================================================================
# A target that exists locally but is git-ignored is broken for everyone else.
echo "Check 2: broken internal links"

while read -r rel; do
    dir="$(dirname "${REPO_ROOT}/${rel}")"
    while read -r link; do
        [[ "${link}" =~ ^(https?|mailto): ]] && continue
        link="${link%%#*}"
        [[ -z "${link}" ]] && continue
        if [[ ! -e "${dir}/${link}" ]]; then
            fail "Broken: ${rel} -> ${link}"
        elif ignored "$(realpath -m --relative-to="${REPO_ROOT}" "${dir}/${link}")"; then
            fail "Link target is git-ignored: ${rel} -> ${link}"
        fi
    done < <(grep -oP '\]\(\K[^)]+' "${REPO_ROOT}/${rel}" || true)
done < <(md_files)
flush_errors

# =============================================================================
# Check 3: link fragments resolve to an anchor
# =============================================================================
# Anchors are explicit <a id="..."></a> tags or the slug GitHub derives from a heading.
echo "Check 3: internal link fragments resolve to an anchor"

ANCHOR_CACHE="$(mktemp -d)"
anchors_of() {
    local f="$1" key
    key="${ANCHOR_CACHE}/$(printf '%s' "${f}" | md5sum | cut -d' ' -f1)"
    if [[ ! -f "${key}" ]]; then
        {
            grep -oP '<a\s+(id|name)="\K[^"]+' "${f}" 2>/dev/null || true
            { grep -oP '^#{1,6}[[:space:]]+\K.*' "${f}" 2>/dev/null || true; } \
                | sed -E 's/\[([^]]*)\]\([^)]*\)/\1/g; s/[`*]//g' \
                | tr '[:upper:]' '[:lower:]' \
                | sed -E 's/[^a-z0-9 _-]//g; s/ /-/g'
        } > "${key}"
    fi
    cat "${key}"
}

while read -r rel; do
    mdfile="${REPO_ROOT}/${rel}"
    dir="$(dirname "${mdfile}")"
    while read -r link; do
        [[ "${link}" =~ ^https?:// ]] && continue
        [[ "${link}" == *"#"* ]] || continue
        frag="${link#*#}"
        target="${link%%#*}"
        [[ -n "${frag}" ]] || continue
        if [[ -z "${target}" ]]; then tfile="${mdfile}"; else tfile="${dir}/${target}"; fi
        [[ -f "${tfile}" && "${tfile}" == *.md ]] || continue
        grep -qxF "${frag}" <(anchors_of "${tfile}") || fail "No such anchor: ${rel} -> ${link}"
    done < <(grep -oP '\]\(\K[^)]+' "${mdfile}" 2>/dev/null || true)
done < <(md_files)
rm -rf "${ANCHOR_CACHE}"
flush_errors

# =============================================================================
# Check 4: no committed .env files
# =============================================================================
echo "Check 4: committed .env files"

while read -r rel; do
    case "$(basename "${rel}")" in
        .env.example) ;;
        .env|.env.*) fail "Found: ${rel}" ;;
    esac
done < <(repo_files)
flush_errors

# =============================================================================
# Check 5: every compose directory has a .env.example
# =============================================================================
echo "Check 5: .env.example per compose directory"

while read -r rel; do
    [[ -f "${REPO_ROOT}/$(dirname "${rel}")/.env.example" ]] || fail "Missing .env.example: $(dirname "${rel}")/"
done < <(repo_files -- 'docker/*docker-compose.yml')
flush_errors

# =============================================================================
# Check 6: no private keys or certificates
# =============================================================================
echo "Check 6: no private keys or certificates"

while read -r rel; do
    case "${rel}" in
        *.pem|*.key|*.crt|*.p12|*.pfx) fail "Key or certificate file: ${rel}" ;;
    esac
    grep -q 'BEGIN [A-Z ]*PRIVATE KEY' "${REPO_ROOT}/${rel}" 2>/dev/null && fail "Private key block: ${rel}"
done < <(repo_files | while read -r f; do [[ -f "${REPO_ROOT}/${f}" ]] && echo "${f}"; done \
         | grep -vx 'scripts/validate-repo.sh')
flush_errors

# =============================================================================
# Check 7: no bare Tailscale addresses (use <tailscale-ip-...>)
# =============================================================================
# Allowed: the CGNAT range 100.64.0.0/10 and Tailscale's resolver 100.100.100.100, both public.
echo "Check 7: no plain Tailscale IPs"

while read -r rel; do
    { grep -nP '(?<!<tailscale-ip[->])\b100\.\d{1,3}\.\d{1,3}\.\d{1,3}\b' "${REPO_ROOT}/${rel}" \
        | grep -vP '100\.64\.0\.0/10|100\.100\.100\.100' || true; } \
        | while read -r m; do fail "Unsanitized Tailscale IP: ${rel}:${m%%:*}"; done
done < <(text_files)
flush_errors

# =============================================================================
# Check 8: no bare RFC 1918 addresses (use <lan-ip-...>)
# =============================================================================
# The Docker address pool 172.16.0.0/12 is a documented network range, not a host address.
echo "Check 8: no plain LAN IPs"

while read -r rel; do
    { grep -nP '\b(192\.168|10\.\d{1,3}|172\.(?:1[6-9]|2[0-9]|3[01]))\.\d{1,3}\.\d{1,3}\b' "${REPO_ROOT}/${rel}" \
        | grep -vP '172\.16\.0\.0/12' || true; } \
        | while read -r m; do fail "Unsanitized LAN IP: ${rel}:${m%%:*}"; done
done < <(text_files)
flush_errors

# =============================================================================
# Check 9: no bare tailnet names (use <tailnet-id>)
# =============================================================================
echo "Check 9: no plain tailnet IDs"

while read -r rel; do
    { grep -nP '(?<!<)\b[a-z0-9-]+\.ts\.net\b' "${REPO_ROOT}/${rel}" | grep -vP '<tailnet-id>' || true; } \
        | while read -r m; do fail "Unsanitized tailnet ID: ${rel}:${m%%:*}"; done
done < <(text_files)
flush_errors

# =============================================================================
# Check 10: no disk labels that encode capacity
# =============================================================================
echo "Check 10: no size-encoding disk labels"

while read -r rel; do
    [[ "${rel}" == scripts/validate-repo.sh ]] && continue
    { grep -niE 'aux[0-9]+tb' "${REPO_ROOT}/${rel}" || true; } \
        | while read -r m; do fail "Size-encoding disk label: ${rel}:${m%%:*}"; done
done < <(text_files)
flush_errors

# =============================================================================
# Check 11: the private sanitization legend is never tracked
# =============================================================================
echo "Check 11: private .local.md files not tracked"

while read -r rel; do
    fail "Tracked private file: ${rel}"
done < <(git -C "${REPO_ROOT}" ls-files -- '*.local.md')
flush_errors

# =============================================================================
# Check 12: no counts that describe a personal media library
# =============================================================================
# "series" is also Prometheus vocabulary, so lines with monitoring terms are skipped.
echo "Check 12: no personal media library counts"

while read -r rel; do
    [[ "${rel}" == scripts/validate-repo.sh ]] && continue
    { grep -nEi "[0-9][0-9,.]*[[:space:]]+(films?|movies|series|seasons?|episodes?|authors?|audiobooks?|ebooks?|albums?|tracks?|titles?)\b" "${REPO_ROOT}/${rel}" \
        | grep -viE "expression|prometheus|promql|metric|series per node|time series" || true; } \
        | while read -r m; do fail "Media library count: ${rel}:${m%%:*}"; done
done < <(text_files)
flush_errors

# =============================================================================
# Check 13: no measured fill level for the archive pool
# =============================================================================
# A configured threshold is a round number; a measured fill level has a decimal point.
echo "Check 13: no measured fill level for the archive pool"

while read -r rel; do
    [[ "${rel}" == scripts/validate-repo.sh ]] && continue
    { grep -nE "mergerfs|MergerFS|archive pool|fill level" "${REPO_ROOT}/${rel}" \
        | grep -E "[0-9]+\.[0-9]+[[:space:]]*%" || true; } \
        | while read -r m; do fail "Archive fill level: ${rel}:${m%%:*}"; done
done < <(text_files)
flush_errors

# =============================================================================
# Check 14: top-level layout
# =============================================================================
# LICENSE stays in the root, where GitHub's license detection looks. SECURITY.md lives in .github/.
echo "Check 14: files outside directory structure"

while read -r entry; do
    case "${entry}" in
        docs|docker|snippets|runbooks|scripts|ansible|terraform) ;;
        README.md|CLAUDE.md|LICENSE|.gitignore|.github|.claude) ;;
        *) fail "Unexpected top-level entry: ${entry}" ;;
    esac
done < <(repo_files | cut -d/ -f1 | sort -u)
flush_errors

# =============================================================================
# Check 15: no merge conflict markers
# =============================================================================
echo "Check 15: no merge conflict markers"

while read -r rel; do
    { grep -nE '^(<<<<<<< |=======$|>>>>>>> )' "${REPO_ROOT}/${rel}" || true; } \
        | while read -r m; do fail "Merge conflict marker: ${rel}:${m%%:*}"; done
done < <(text_files)
flush_errors

# =============================================================================
# Check 16: no refs outside the standard namespaces
# =============================================================================
# A commit that no branch reaches is never reviewed, but a mirror push publishes it.
echo "Check 16: no refs outside the standard namespaces"

if git -C "${REPO_ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
    while read -r ref; do
        case "${ref}" in
            refs/heads/*|refs/tags/*|refs/remotes/*|refs/stash|refs/notes/*) ;;
            *) fail "Ref outside standard namespaces: ${ref} (remove with: git update-ref -d ${ref})" ;;
        esac
    done < <(git -C "${REPO_ROOT}" for-each-ref --format='%(refname)')
fi
flush_errors

# =============================================================================
# Check 17: ASCII punctuation only
# =============================================================================
# Allowed exceptions: box-drawing characters (U+2500-U+257F) and the section sign (U+00A7).
echo "Check 17: plain-ASCII punctuation"

while read -r rel; do
    { grep -noP '(?![\x{2500}-\x{257F}\x{00A7}])[^\x00-\x7F]' "${REPO_ROOT}/${rel}" || true; } \
        | while read -r m; do fail "Non-ASCII character: ${rel}:${m}"; done
done < <(text_files)
flush_errors

# =============================================================================
# Check 18: bold marks a label, not emphasis inside a sentence
# =============================================================================
echo "Check 18: bold as label, not mid-sentence emphasis"

while read -r rel; do
    { grep -nE "[a-zA-Z0-9,;:)] \*\*[^*]+\*\*" "${REPO_ROOT}/${rel}" || true; } \
        | while read -r m; do fail "Mid-sentence bold: ${rel}:${m%%:*}"; done
done < <(md_files)
flush_errors

# =============================================================================
# Check 19: repository content is English
# =============================================================================
# Only German words without an English homograph, so a hit is real German text.
echo "Check 19: repository content is English"

while read -r rel; do
    [[ "${rel}" == scripts/validate-repo.sh ]] && continue
    { grep -nwiE "nicht|wurde|wurden|werden|damit|deshalb|sondern|jedoch|bereits|zwischen|Lernprojekt|Rechner|Beispiel" "${REPO_ROOT}/${rel}" || true; } \
        | while read -r m; do fail "German text: ${rel}:${m%%:*}"; done
done < <(text_files)
flush_errors

# =============================================================================
# Check 20: house style - the platform is the subject
# =============================================================================
# Refused: "the operator", "operator's", and "operator" as a device label.
echo "Check 20: house style - the platform is the subject"

while read -r rel; do
    [[ "${rel}" == scripts/validate-repo.sh ]] && continue
    { grep -noiP "\bthe operator\b|\boperator's\b|\boperators?[ -](phone|workstations?|devices?)\b" "${REPO_ROOT}/${rel}" || true; } \
        | while read -r m; do fail "Narrated operator: ${rel}:${m%%:*}"; done
done < <(text_files)
flush_errors

# =============================================================================
# Check 21: no duplicate second-level headings within a document
# =============================================================================
echo "Check 21: duplicate markdown headings"

while read -r rel; do
    { grep -P '^## ' "${REPO_ROOT}/${rel}" || true; } | sort | uniq -d \
        | while read -r dup; do fail "Duplicate heading in ${rel}: ${dup}"; done
done < <(md_files)
flush_errors

# =============================================================================
# Check 22: balanced code fences
# =============================================================================
echo "Check 22: balanced markdown code fences"

while read -r rel; do
    fences="$(grep -c '^[[:space:]]*```' "${REPO_ROOT}/${rel}" || true)"
    (( fences % 2 == 0 )) || fail "Unbalanced code fence (${fences} found): ${rel}"
done < <(md_files)
flush_errors

# =============================================================================
# Check 23: table rows stay on one line
# =============================================================================
echo "Check 23: markdown table rows stay on one line"

while read -r rel; do
    while read -r finding; do fail "${finding}"; done < <(awk -v file="${rel}" '
        /^[[:space:]]*```/ { fence = !fence; next }
        fence { next }
        /^\|/ { line = $0; sub(/[ \t]+$/, "", line); if (line !~ /\|$/) printf "Table row broken across lines: %s:%d\n", file, NR }
    ' "${REPO_ROOT}/${rel}")
done < <(md_files)
flush_errors

# =============================================================================
# Check 24: a paragraph directly above --- or === renders as a heading
# =============================================================================
echo "Check 24: no paragraph turned into a heading by the rule below it"

while read -r rel; do
    while read -r finding; do fail "${finding}"; done < <(awk -v file="${rel}" '
        NR == 1 && $0 ~ /^---[[:space:]]*$/ { fm = 1; next }
        fm && $0 ~ /^---[[:space:]]*$/ { fm = 0; next }
        fm { next }
        /^[[:space:]]*```/ { fence = !fence }
        fence { prev = $0; next }
        /^(-{3,}|={3,})[[:space:]]*$/ {
            if (prev != "" && prev !~ /^[[:space:]]*$/ && prev !~ /^[[:space:]]*[|>#]/ \
                && prev !~ /^[[:space:]]*([-*+]|[0-9]+\.)[[:space:]]/)
                printf "%s:%d: paragraph renders as a heading - blank line missing above the rule\n", file, NR
        }
        { prev = $0 }
    ' "${REPO_ROOT}/${rel}")
done < <(md_files)
flush_errors

# =============================================================================
# Check 25: every document under docs/ and runbooks/ is linked from an index
# =============================================================================
# Reachable means linked directly from README.md or runbooks/README.md.
echo "Check 25: every document is reachable from an index"

LINKED_LIST="$(mktemp)"
for idx in README.md runbooks/README.md; do
    idx_dir="$(dirname "${REPO_ROOT}/${idx}")"
    while read -r link; do
        [[ "${link}" =~ ^https?:// ]] && continue
        link="${link%%#*}"
        [[ -z "${link}" ]] && continue
        realpath -m --relative-to="${REPO_ROOT}" "${idx_dir}/${link}" >> "${LINKED_LIST}"
    done < <(grep -oP '\]\(\K[^)]+' "${REPO_ROOT}/${idx}" || true)
done

while read -r rel; do
    grep -qxF "${rel}" "${LINKED_LIST}" || fail "Not linked from any index: ${rel}"
done < <(md_files | grep -E '^(docs|runbooks)/')
rm -f "${LINKED_LIST}"
flush_errors

# =============================================================================
# Check 26: backticked repository paths exist
# =============================================================================
# A path that git ignores on purpose (real inventory, .env files) passes.
echo "Check 26: backticked repository paths exist"

while read -r rel; do
    while read -r ref; do
        [[ -z "${ref}" ]] && continue
        [[ -e "${REPO_ROOT}/${ref}" ]] && continue
        ignored "${ref}" && continue
        fail "Path does not exist: ${rel} -> ${ref}"
    done < <({ grep -oP '`\K(snippets|ansible|scripts|docker|docs|runbooks)/[A-Za-z0-9_./-]+(?=`)' "${REPO_ROOT}/${rel}" || true; } | sort -u)
done < <(md_files)
flush_errors

# =============================================================================
# Check 27: counted claims in the README match the repository
# =============================================================================
# A missing claim is an error too, so a sentence cannot drop out of the check unnoticed.
echo "Check 27: counted claims match the repository"

README_FILE="${REPO_ROOT}/README.md"

compare_claim() {
    local label="$1" claimed="$2" actual="$3"
    if [[ -z "${claimed}" ]]; then
        fail "Claim not found in README: ${label}"
    elif [[ "${claimed}" != "${actual}" ]]; then
        fail "${label}: README says ${claimed}, repository has ${actual}"
    fi
}

runbooks_actual="$(repo_files -- 'runbooks/*.md' | grep -vc 'runbooks/README.md$' || true)"
roles_actual="$(repo_files -- 'ansible/roles/' | cut -d/ -f3 | sort -u | wc -l)"
playbooks_actual="$(repo_files -- 'ansible/playbooks/*.yml' | wc -l)"
decisions_actual="$(repo_files -- 'docs/decisions/*.md' | wc -l)"
checks_actual="$(grep -cE '^echo "Check [0-9]+' "${SELF}" || true)"

compare_claim "runbook count" "$({ grep -oP '\b\K[0-9]+(?= runbooks\b)' "${README_FILE}" || true; } | head -1)" "${runbooks_actual}"
compare_claim "playbook count" "$({ grep -oP '\b\K[0-9]+(?= playbooks\b)' "${README_FILE}" || true; } | head -1)" "${playbooks_actual}"
compare_claim "role count" "$({ grep -oP '\b\K[0-9]+(?= roles\b)' "${README_FILE}" || true; } | head -1)" "${roles_actual}"
compare_claim "decision record count" "$({ grep -oP '\b\K[0-9]+(?= decision records\b)' "${README_FILE}" || true; } | head -1)" "${decisions_actual}"
compare_claim "validator check count" "$({ grep -oP '\b\K[0-9]+(?= checks\b)' "${README_FILE}" || true; } | head -1)" "${checks_actual}"
flush_errors

# =============================================================================
# Check 28: service documents
# =============================================================================
# Each has an Access Model, and every node it names has a node document.
echo "Check 28: service documents have an access model and name documented nodes"

while read -r rel; do
    f="${REPO_ROOT}/${rel}"
    grep -q '^## Access Model' "${f}" || fail "Missing '## Access Model': ${rel}"
    nodes="$({ grep -ohE '\b(vm[0-9]{3}|lxc[0-9]{3})\b' "${f}" || true; } | sort -u)"
    [[ -n "${nodes}" ]] || fail "Service document names no node: ${rel}"
    while read -r node; do
        [[ -z "${node}" ]] && continue
        [[ -f "${REPO_ROOT}/docs/nodes/${node}.md" ]] || fail "Names a node with no node document: ${rel} -> ${node}"
    done <<< "${nodes}"
done < <(repo_files -- 'docs/services/*.md')
flush_errors

# =============================================================================
# Check 29: node documents
# =============================================================================
# Required sections, and a Tailscale tag that tailscale-acl.md defines in tagOwners.
echo "Check 29: node documents carry tag, configuration management and failure impact"

ACL_DOC="${REPO_ROOT}/docs/platform/tailscale-acl.md"
while read -r rel; do
    f="${REPO_ROOT}/${rel}"
    grep -q '^## Failure Impact' "${f}" || fail "Missing '## Failure Impact': ${rel}"
    grep -q '^## Configuration Management' "${f}" || fail "Missing '## Configuration Management': ${rel}"
    tag="$({ grep -oP '^- Tag: `\Ktag:[a-z0-9-]+' "${f}" || true; } | head -1)"
    if [[ -z "${tag}" ]]; then
        fail "No '- Tag: \`tag:...\`' line: ${rel}"
    elif ! grep -q "\"${tag}\":" "${ACL_DOC}"; then
        fail "Tag not defined in tailscale-acl.md tagOwners: ${rel} -> ${tag}"
    fi
done < <(repo_files -- 'docs/nodes/*.md')
flush_errors

# =============================================================================
# Check 30: runbook contract
# =============================================================================
# Sections for preconditions, verification, failure modes and rollback ("none, because ..." is a
# valid rollback), plus a Last exercised line that starts with a date or "never".
echo "Check 30: runbook contract"

while read -r rel; do
    f="${REPO_ROOT}/${rel}"
    for section in Precondition Verification Failure Rollback; do
        grep -qiE "^##[[:space:]].*${section}" "${f}" || fail "Missing '${section}' section: ${rel}"
    done
    grep -qE '^- \*\*Last exercised:\*\* (never|[0-9]{4}-[0-9]{2}-[0-9]{2})' "${f}" \
        || fail "Missing '- **Last exercised:** <YYYY-MM-DD, result> | never' line: ${rel}"
done < <(repo_files -- 'runbooks/*.md' | grep -v 'runbooks/README.md$')
flush_errors

# =============================================================================
# Check 31: decision records carry a status
# =============================================================================
echo "Check 31: decision records carry a status"

while read -r rel; do
    [[ "${rel}" == docs/decisions/design-decisions.md ]] && continue
    status="$(awk '/^## Status/ { found = 1; next } found && NF { print; exit }' "${REPO_ROOT}/${rel}")"
    if [[ -z "${status}" ]]; then
        fail "Missing '## Status' section: ${rel}"
    elif ! grep -qE '^(Proposed|Accepted|Implemented|Superseded|Withdrawn)\b' <<< "${status}"; then
        fail "Status must start with Proposed, Accepted, Implemented, Superseded or Withdrawn: ${rel}"
    fi
done < <(repo_files -- 'docs/decisions/*.md')
flush_errors

# =============================================================================
# Check 32: documents stay within their length ceiling
# =============================================================================
# Ceilings are in docs/CONVENTIONS.md. known-errors.md is measured per entry instead of as a whole.
echo "Check 32: documents stay within their length ceiling"

ceiling_for() {
    case "$1" in
        README.md) echo 160 ;;
        CLAUDE.md) echo 120 ;;
        .claude/agents/*) echo 60 ;;
        docs/CONVENTIONS.md) echo 200 ;;
        docs/decisions/design-decisions.md) echo 320 ;;
        docs/decisions/*) echo 130 ;;
        docs/nodes/*|docs/services/*) echo 130 ;;
        docs/architecture/*) echo 180 ;;
        docs/platform/incidents/*) echo 160 ;;
        docs/platform/known-errors.md) echo 0 ;;
        # Carries the full ACL policy and its tests as JSON, which is the point of the page.
        docs/platform/tailscale-acl.md) echo 560 ;;
        docs/platform/*) echo 320 ;;
        runbooks/*) echo 180 ;;
        *) echo 0 ;;
    esac
}

while read -r rel; do
    limit="$(ceiling_for "${rel}")"
    (( limit > 0 )) || continue
    lines="$(wc -l < "${REPO_ROOT}/${rel}")"
    (( lines <= limit )) || fail "${rel} has ${lines} lines, ceiling ${limit}"
done < <(md_files)

KE_FILE="${REPO_ROOT}/docs/platform/known-errors.md"
if [[ -f "${KE_FILE}" ]]; then
    while read -r finding; do fail "${finding}"; done < <(awk '
        /^## / { if (id != "" && NR - start > 70) printf "known-errors.md %s has %d lines, ceiling 70\n", id, NR - start; id = ""; }
        /^## KE-[0-9]+:/ { id = $2; sub(/:$/, "", id); start = NR }
        END { if (id != "" && NR - start + 1 > 70) printf "known-errors.md %s has %d lines, ceiling 70\n", id, NR - start + 1 }
    ' "${KE_FILE}")
fi
flush_errors

# =============================================================================
# Check 33: register entries are anchored and listed in their index
# =============================================================================
echo "Check 33: register entries are anchored and listed in their index"

DD_FILE="${REPO_ROOT}/docs/decisions/design-decisions.md"
if [[ -f "${KE_FILE}" ]]; then
    while read -r n; do
        grep -qF "<a id=\"ke-${n}\"></a>" "${KE_FILE}" || fail "KE-${n} carries no <a id=\"ke-${n}\"></a> anchor"
        grep -qE "^\| \[KE-${n}\]\(#ke-${n}\) \|" "${KE_FILE}" || fail "KE-${n} is missing from the index"
    done < <(grep -oP '^## KE-\K[0-9]+(?=:)' "${KE_FILE}" || true)
fi
if [[ -f "${DD_FILE}" ]]; then
    while read -r n; do
        grep -qF "<a id=\"dd-${n}\"></a>" "${DD_FILE}" || fail "Decision ${n} carries no <a id=\"dd-${n}\"></a> anchor"
        grep -qE "^\| \[${n}\]\(#dd-${n}\) \|" "${DD_FILE}" || fail "Decision ${n} is missing from the index"
    done < <(grep -oP '^## \K[0-9]+(?=\. )' "${DD_FILE}" || true)
fi
flush_errors

# =============================================================================
# Check 34: an Enforced control cites its evidence
# =============================================================================
# Shallow on purpose: it cannot judge the evidence, only insist that a link or path is given.
echo "Check 34: Enforced controls cite their evidence"

SEC_DOC="${REPO_ROOT}/docs/platform/security-controls.md"
if [[ -f "${SEC_DOC}" ]]; then
    while read -r row; do
        grep -qE '\[[^]]+\]\(|`' <<< "${row}" \
            || fail "Enforced without evidence: $(sed -E 's/^\|[[:space:]]*([^|]+)\|.*/\1/; s/[[:space:]]*$//' <<< "${row}")"
    done < <(grep -E '^\|[[:space:]]*A\.[0-9.]+ .*\|[[:space:]]*Enforced[[:space:]]*\|' "${SEC_DOC}" || true)
fi
flush_errors

# =============================================================================
# Check 35: the alerting table in monitoring.md matches the rules file
# =============================================================================
echo "Check 35: alerting table matches the rules file"

RULES_FILE="${REPO_ROOT}/docker/monitoring/prometheus/rules/alert.rules.yml"
MON_DOC="${REPO_ROOT}/docs/platform/monitoring.md"
if [[ -f "${RULES_FILE}" && -f "${MON_DOC}" ]]; then
    doc_table="$(sed -n '/^| Group | Rules |/,/^$/p' "${MON_DOC}")"
    if [[ -z "${doc_table}" ]]; then
        fail "No '| Group | Rules |' table in docs/platform/monitoring.md"
    else
        file_groups="$(grep -oE '^  - name: [a-z_]+' "${RULES_FILE}" | sed 's/.*name: //' | sort -u)"
        file_rules="$(grep -oE '^      - alert: [A-Za-z]+' "${RULES_FILE}" | sed 's/.*alert: //' | sort -u)"
        doc_groups="$(grep -oE '^\| `[a-z_]+`' <<< "${doc_table}" | tr -d '|` ' | sort -u)"
        doc_rules="$(grep -oE '`[A-Z][A-Za-z]+`' <<< "${doc_table}" | tr -d '`' | sort -u)"
        while read -r x; do [[ -n "${x}" ]] && fail "Group missing from monitoring.md table: ${x}"; done < <(comm -23 <(echo "${file_groups}") <(echo "${doc_groups}"))
        while read -r x; do [[ -n "${x}" ]] && fail "Group in monitoring.md table but not in rules: ${x}"; done < <(comm -13 <(echo "${file_groups}") <(echo "${doc_groups}"))
        while read -r x; do [[ -n "${x}" ]] && fail "Alert missing from monitoring.md table: ${x}"; done < <(comm -23 <(echo "${file_rules}") <(echo "${doc_rules}"))
        while read -r x; do [[ -n "${x}" ]] && fail "Alert in monitoring.md table but not in rules: ${x}"; done < <(comm -13 <(echo "${file_rules}") <(echo "${doc_rules}"))
    fi
fi
flush_errors

# =============================================================================
# Check 36: container images carry an explicit version
# =============================================================================
echo "Check 36: container images carry an explicit tag"

while read -r rel; do
    while read -r line; do
        image="$(sed -E 's/.*image:[[:space:]]*//; s/[[:space:]]*(#.*)?$//' <<< "${line}" | tr -d "\"'")"
        [[ -z "${image}" || "${image}" == *'${'* ]] && continue
        if [[ "${image}" != *:* ]]; then
            fail "Image without a tag: ${rel} -> ${image}"
        elif [[ "${image}" =~ :(latest|main|master|stable)$ ]]; then
            fail "Image not pinned: ${rel} -> ${image}"
        fi
    done < <(grep -E '^\s*image:' "${REPO_ROOT}/${rel}" || true)
done < <(repo_files -- 'docker/*docker-compose.yml')
flush_errors

# =============================================================================
# Check 37: secret-looking Ansible variables are vaulted or referenced
# =============================================================================
# The key name must end in the secret word; "password_authentication" is an sshd setting.
echo "Check 37: secret-looking variables are not literals"

while read -r rel; do
    while read -r line; do
        value="$(sed -E 's/^[^:]*:[[:space:]]*//; s/[[:space:]]*$//' <<< "${line}")"
        [[ -z "${value}" || "${value}" == '!vault'* || "${value}" == *'{{'* || "${value}" == '|' || "${value}" == '>' ]] && continue
        fail "Literal value for a secret-looking key: ${rel} -> $(sed -E 's/[[:space:]]*([^:]+):.*/\1/' <<< "${line}")"
    done < <(grep -E '^[[:space:]]*[a-z_]*(password|passwd|secret|token|api_key|secret_key|private_key)[[:space:]]*:' "${REPO_ROOT}/${rel}" || true)
done < <(repo_files -- 'ansible/*.yml' 'ansible/*.yaml')
flush_errors

# =============================================================================
# Check 38: every Ansible role is documented in docs/platform/ansible.md
# =============================================================================
# Matched as `role_name` in backticks, so a role is not covered by a word in running text.
echo "Check 38: every Ansible role is documented"

while read -r role; do
    grep -qF -- "\`${role}\`" "${REPO_ROOT}/docs/platform/ansible.md" || fail "Role not documented in docs/platform/ansible.md: ${role}"
done < <(repo_files -- 'ansible/roles/' | cut -d/ -f3 | sort -u)
flush_errors

# =============================================================================
# Check 39: state-changing playbooks import the preflight gate
# =============================================================================
# Exempt: the gate itself and the two read-only playbooks, which must run during an incident.
echo "Check 39: state-changing playbooks import the preflight gate"

while read -r rel; do
    case "$(basename "${rel}")" in
        preflight.yml|fleet-health-check.yml|fleet-snapshot.yml) continue ;;
    esac
    grep -q '^  import_playbook: preflight.yml$' "${REPO_ROOT}/${rel}" || fail "Missing preflight import: ${rel}"
done < <(repo_files -- 'ansible/playbooks/*.yml')
flush_errors

# =============================================================================
# Check 40: every gated playbook is swept for drift or excluded on record
# =============================================================================
echo "Check 40: gated playbooks are swept or excluded on record"

DRIFT_CONF="${REPO_ROOT}/ansible/drift-sweep.conf"
PLAYBOOK_DIR="${REPO_ROOT}/ansible/playbooks"
if [[ -f "${DRIFT_CONF}" ]]; then
    # Same section ranges the sweep script reads.
    swept="$(sed -n '/^\[playbooks\]/,/^\[baseline\]/p' "${DRIFT_CONF}" | grep -E '^[a-z0-9-]+$' || true)"
    excluded="$(sed -n '/^\[excluded\]/,/^\[playbooks\]/p' "${DRIFT_CONF}" | grep -E '^[a-z0-9-]+$' || true)"
    while read -r pbfile; do
        [[ -z "${pbfile}" ]] && continue
        pb="$(basename "${pbfile}" .yml)"
        in_swept=0; in_excluded=0
        grep -qxF "${pb}" <<< "${swept}" && in_swept=1
        grep -qxF "${pb}" <<< "${excluded}" && in_excluded=1
        if (( in_swept && in_excluded )); then
            fail "${pb} is both swept and excluded in drift-sweep.conf"
        elif (( ! in_swept && ! in_excluded )); then
            fail "${pb} imports the preflight gate but drift-sweep.conf neither sweeps nor excludes it"
        fi
    done < <(grep -lE '^[[:space:]]*import_playbook:[[:space:]]*preflight\.yml' "${PLAYBOOK_DIR}"/*.yml 2>/dev/null || true)
    while read -r name; do
        [[ -f "${PLAYBOOK_DIR}/${name}.yml" ]] || fail "drift-sweep.conf names ${name}, which is not a playbook"
    done < <(printf '%s\n%s\n' "${swept}" "${excluded}" | grep -vE '^$' || true)
fi
flush_errors

# =============================================================================
# Check 41: documents describe the platform, not the tooling or the writing
# =============================================================================
# The README section on how the repository is built, CLAUDE.md, .claude/ and CONVENTIONS.md
# are where the tooling is named. Validator check numbers are cited nowhere: they change.
echo "Check 41: no tooling, session or check-number narration in documents"

while read -r rel; do
    case "${rel}" in
        CLAUDE.md|.claude/*|docs/CONVENTIONS.md) text="" ;;
        README.md) text="$(awk '/^## How this repository is built/ { skip = 1; next } /^## / { skip = 0 } !skip { printf "%d:%s\n", NR, $0 }' "${REPO_ROOT}/${rel}")" ;;
        *) text="$(awk '{ printf "%d:%s\n", NR, $0 }' "${REPO_ROOT}/${rel}")" ;;
    esac
    { grep -iP '^\d+:.*\b(this session|learning mode|interviewer|claude|assistant)\b' <<< "${text}" || true; } \
        | while read -r m; do fail "Tooling or session narration: ${rel}:${m%%:*}"; done
done < <(md_files)
while read -r rel; do
    { grep -nP '\bChecks? [0-9]+\b' "${REPO_ROOT}/${rel}" || true; } \
        | while read -r m; do fail "Validator check number cited: ${rel}:${m%%:*}"; done
done < <(md_files)
flush_errors

# =============================================================================
# Check 42: assistant rules and agents carry no dates
# =============================================================================
# A date in a rules file is a status claim, and status lives in the documents that own it.
echo "Check 42: CLAUDE.md and agent definitions carry no dates"

while read -r rel; do
    { grep -nE '\b20[0-9]{2}-[0-9]{2}(-[0-9]{2})?\b' "${REPO_ROOT}/${rel}" || true; } \
        | while read -r m; do fail "Date in a rules file: ${rel}:${m%%:*}"; done
done < <(md_files | grep -E '^(CLAUDE\.md|\.claude/agents/)')
flush_errors

# =============================================================================
# Check 43: no comment block longer than twenty lines in code and configuration
# =============================================================================
# Longer reasoning is a decision record or a known-error entry. Exception: platform-restore.sh
# prints its header as the usage text.
echo "Check 43: comment blocks stay within twenty lines"

while read -r rel; do
    [[ "${rel}" == snippets/scripts/platform-restore.sh ]] && continue
    while read -r finding; do fail "${finding}"; done < <(awk -v file="${rel}" '
        /^[[:space:]]*#/ { run++; if (run == 21) printf "Comment block over twenty lines: %s:%d\n", file, NR - 20; next }
        { run = 0 }
    ' "${REPO_ROOT}/${rel}")
done < <(text_files | grep -E '\.(ya?ml|j2|sh|conf|service|timer|py|nft|cfg)$')
flush_errors

# =============================================================================
# Check 44: image versions are stated only in the compose files
# =============================================================================
# A document names the stack; the version it runs is read from docker/<stack>/docker-compose.yml.
echo "Check 44: image versions are not repeated in documents"

while read -r compose; do
    while read -r img; do
        tag="${img##*:}"; short="${img%:*}"; short="${short##*/}"
        [[ "${tag}" == "${img}" || "${tag}" == *'${'* || "${tag}" != *[0-9]* ]] && continue
        while read -r rel; do
            { grep -nwF -- "${tag}" "${REPO_ROOT}/${rel}" | grep -iF -- "${short}" || true; } \
                | while read -r m; do fail "Image version repeated: ${rel}:${m%%:*} (${short}:${tag}, owned by ${compose})"; done
        done < <(md_files | grep -E '^(docs/|README\.md$)')
    done < <(grep -E '^\s*image:' "${REPO_ROOT}/${compose}" \
             | sed -E "s/.*image:[[:space:]]*//; s/[\"']//g; s/[[:space:]]*(#.*)?$//")
done < <(repo_files -- 'docker/*docker-compose.yml')
flush_errors

# =============================================================================
# Check 45: ansible-lint on changed Ansible files (local only)
# =============================================================================
# CI lints every push in .github/workflows/ansible-lint.yml, so this check runs only when the
# working tree changes something under ansible/. Without the real vault password (it exists only on
# the control node) a throwaway one is used: the syntax check parses !vault values without
# decrypting them.
echo "Check 45: ansible-lint (production profile)"

changed="$( { git -C "${REPO_ROOT}" diff --cached --name-only; git -C "${REPO_ROOT}" diff --name-only HEAD; \
              git -C "${REPO_ROOT}" ls-files --others --exclude-standard; } 2>/dev/null | sort -u || true)"

if ! command -v ansible-lint >/dev/null 2>&1; then
    echo "  SKIP: ansible-lint not in PATH"
elif ! grep -q '^ansible/' <<< "${changed}"; then
    echo "  SKIP: no changes under ansible/"
else
    vault_pw_file=""
    if [[ ! -r "${HOME}/.vault_pass" ]]; then
        vault_pw_file="$(mktemp)"
        echo 'syntax-check-only' > "${vault_pw_file}"
        export ANSIBLE_VAULT_PASSWORD_FILE="${vault_pw_file}"
    fi
    lint_output="$(cd "${REPO_ROOT}/ansible" && ansible-lint --nocolor . 2>&1)" && lint_rc=0 || lint_rc=$?
    if [[ -n "${vault_pw_file}" ]]; then
        rm -f "${vault_pw_file}"
        unset ANSIBLE_VAULT_PASSWORD_FILE
    fi
    if (( lint_rc != 0 )); then
        sed 's/^/  /' <<< "${lint_output}"
        fail "ansible-lint failed (exit ${lint_rc})"
    fi
fi
flush_errors

# =============================================================================
# Check 46: the commit-message hook is installed (local only)
# =============================================================================
# Under CI the commit-messages workflow is the gate.
echo "Check 46: commit-message hook installed on this machine"

if [[ -n "${CI:-}" ]]; then
    echo "  SKIP: under CI"
elif git -C "${REPO_ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
    hooks_dir="$(git -C "${REPO_ROOT}" config --get core.hooksPath || git -C "${REPO_ROOT}" rev-parse --git-path hooks)"
    [[ "${hooks_dir}" = /* ]] || hooks_dir="${REPO_ROOT}/${hooks_dir}"
    hook_path="${hooks_dir}/commit-msg"
    if [[ ! -x "${hook_path}" ]]; then
        fail "No executable commit-msg hook at ${hook_path} (install: git config core.hooksPath scripts/hooks)"
    elif ! grep -q 'commit-msg-lint' "${hook_path}" 2>/dev/null \
         && [[ "$(readlink -f "${hook_path}" 2>/dev/null)" != *commit-msg-lint.sh ]]; then
        fail "commit-msg hook does not run scripts/commit-msg-lint.sh: ${hook_path}"
    fi
fi
flush_errors

# =============================================================================
# Results
# =============================================================================
echo ""
echo "=== Done ==="
echo "Checks run: $(grep -cE '^echo "Check [0-9]+' "${SELF}")"
if (( ERRORS > 0 )); then
    echo "FAIL: ${ERRORS} error(s) found."
    exit 1
fi
echo "PASS: All checks passed."
