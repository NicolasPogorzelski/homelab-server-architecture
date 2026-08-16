#!/usr/bin/env bash
#
# storage-permissions.sh - verify (and optionally repair) the filesystem side of
# the VM102 share model.
#
# Why this exists: smb.conf documents what Samba enforces when Samba is involved.
# It says nothing about what is actually on the disks. Between those two things a
# gap opened, and it went unnoticed from the pool's creation on 2025-12-26 until
# 2026-08-16 - see docs/platform/storage-permissions.md for the full account.
#
# The check runs per branch, never against /mnt/mergerfs. MergerFS answers a stat
# from the first branch that holds the path (category.search=ff), so the union
# view shows one of six disks and hides disagreement between them. That is
# precisely how the original defect stayed invisible.
#
# Modes:
#   --check     report deviations, exit 1 if any were found (default)
#   --apply     repair them
#   --metrics   write the node_exporter textfile metric, always exit 0
#
set -uo pipefail

CONF=${STORAGE_PERM_CONF:-/etc/storage-permissions.conf}
TEXTFILE_DIR=${STORAGE_PERM_TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}
PROM_FILE="${TEXTFILE_DIR}/storage_permissions.prom"
POOL=${STORAGE_PERM_POOL:-/mnt/mergerfs}

mode=check
case "${1:-}" in
  --check|"") mode=check ;;
  --apply)    mode=apply ;;
  --metrics)  mode=metrics ;;
  *) echo "usage: $0 [--check|--apply|--metrics]" >&2; exit 2 ;;
esac

[ -r "$CONF" ] || { echo "config not readable: $CONF" >&2; exit 2; }

entries=()
while read -r keyword rest; do
  case "$keyword" in
    entry) entries+=("$rest") ;;
    ''|'#'*) ;;
  esac
done < <(sed 's/#.*//' "$CONF")

# The branch list is read from the running mergerfs instance, not from a config
# file and not from fstab. Three reasons, in order of weight:
#   1. Add a disk to the pool and the check covers it on the next run. A hand-kept
#      list would have to be remembered at exactly the moment everyone is busy
#      moving data - which is how the branch that broke this model got missed.
#   2. The control file reports what is mounted; fstab reports what was intended.
#   3. The repository must not carry the real disk labels (validate-repo.sh
#      Check 18), so the list cannot live in the Ansible role either.
branch_spec=$(getfattr --only-values -n user.mergerfs.branches "${POOL}/.mergerfs" 2>/dev/null || true)
[ -n "$branch_spec" ] || { echo "cannot read mergerfs branches from ${POOL}/.mergerfs" >&2; exit 2; }

# Two guards on one line of parsing, both earned the hard way on 2026-08-16.
#
# `printf '%s\n'` and the `|| [ -n "$b" ]`: getfattr --only-values emits no
# trailing newline, and `while read` discards a final unterminated line without a
# word of complaint. The first version of this script therefore checked five of
# six branches and reported "matrix intact" - skipping precisely the branch whose
# missing setgid bit this whole role exists to catch. A checker that is silently
# blind to the thing it checks is the exact defect it was written to find.
#
# The count assertion below is the second guard: it makes the omission loud
# rather than trusting that the parsing stays correct.
branches=()
while IFS= read -r b || [ -n "$b" ]; do
  [ -n "$b" ] && branches+=("${b%%=*}")
done < <(printf '%s\n' "$branch_spec" | tr ':' '\n')

expected=$(printf '%s' "$branch_spec" | tr -cd ':' | wc -c)
expected=$(( expected + 1 ))
if [ "${#branches[@]}" -ne "$expected" ]; then
  echo "branch parsing lost entries: found ${#branches[@]}, expected ${expected} in '${branch_spec}'" >&2
  exit 2
fi

# Violations are counted per kind, not per path. Six branches times twelve paths
# times five kinds would be 360 Prometheus series to answer one question: is the
# model intact. The per-path detail goes to stdout, which the timer captures into
# the journal, so it is there when the answer is no.
declare -A count=([owner]=0 [group]=0 [dir_mode]=0 [file_mode]=0 [setgid]=0)
findings=""

# find's -perm /MASK matches "any of these bits set". Turning a maximum into the
# bits that must NOT appear is therefore the whole trick: everything outside the
# allowance is a violation, and one find call finds all of it.
forbidden() { printf '%04o' $(( 07777 & ~8#$1 )); }

for branch in "${branches[@]}"; do
  for entry in "${entries[@]}"; do
    read -r name owner group dir_max file_max want_sgid <<<"$entry"
    path="${branch}/${name}"
    [ -d "$path" ] || continue

    declare -A hit=()
    # A literal "-" means the owner is deliberately not pinned. The roms share is
    # the one case: it carries no `force user`, so files legitimately belong to
    # whichever of its three accounts wrote them. Checking it would produce a
    # violation count that never reaches zero, and a check that is always red is
    # not read - the same lesson DiskSpaceCritical already cost this platform.
    if [ "$owner" = "-" ]; then
      hit[owner]=0
    else
      hit[owner]=$(find "$path" ! -user "$owner" -printf . 2>/dev/null | wc -c)
    fi
    hit[group]=$(find "$path" ! -group "$group" -printf . 2>/dev/null | wc -c)
    hit[dir_mode]=$(find "$path" -type d -perm "/$(forbidden "$dir_max")" -printf . 2>/dev/null | wc -c)
    hit[file_mode]=$(find "$path" -type f -perm "/$(forbidden "$file_max")" -printf . 2>/dev/null | wc -c)
    if [ "$want_sgid" = "yes" ]; then
      hit[setgid]=$(find "$path" -type d ! -perm -g+s -printf . 2>/dev/null | wc -c)
    else
      hit[setgid]=0
    fi

    for kind in owner group dir_mode file_mode setgid; do
      [ "${hit[$kind]}" -eq 0 ] && continue
      count[$kind]=$(( count[$kind] + hit[$kind] ))
      findings+="  ${branch##*/}/${name}: ${hit[$kind]} x ${kind}"$'\n'
    done

    [ "$mode" = apply ] || continue

    [ "${hit[owner]}" -gt 0 ] && [ "$owner" != "-" ] && find "$path" ! -user "$owner" -exec chown "$owner" {} +
    [ "${hit[group]}" -gt 0 ] && find "$path" ! -group "$group" -exec chgrp "$group" {} +
    [ "${hit[dir_mode]}" -gt 0 ] && \
      find "$path" -type d -perm "/$(forbidden "$dir_max")" -exec chmod "$dir_max" {} +
    [ "${hit[file_mode]}" -gt 0 ] && \
      find "$path" -type f -perm "/$(forbidden "$file_max")" -exec chmod "$file_max" {} +
    # Deliberately g+s and not the absolute mode: a directory can be missing the
    # setgid bit while its other bits are stricter than the maximum, and applying
    # the maximum would then hand out access the check never asked for.
    [ "${hit[setgid]}" -gt 0 ] && find "$path" -type d ! -perm -g+s -exec chmod g+s {} +
  done
done

total=0
for kind in owner group dir_mode file_mode setgid; do
  total=$(( total + count[$kind] ))
done

if [ "$mode" = metrics ]; then
  mkdir -p "$TEXTFILE_DIR"
  # Written to a temporary file and moved into place: node_exporter reads this
  # directory every 15 s and would otherwise be able to read a half-written file.
  tmp=$(mktemp "${PROM_FILE}.XXXXXX")
  {
    echo "# HELP storage_permission_violations Objects deviating from the target matrix on vm102."
    echo "# TYPE storage_permission_violations gauge"
    for kind in owner group dir_mode file_mode setgid; do
      echo "storage_permission_violations{kind=\"${kind}\"} ${count[$kind]}"
    done
    echo "# HELP storage_permission_check_timestamp_seconds Unix time of the last completed check."
    echo "# TYPE storage_permission_check_timestamp_seconds gauge"
    echo "storage_permission_check_timestamp_seconds $(date +%s)"
  } > "$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$PROM_FILE"
fi

if [ "$total" -eq 0 ]; then
  echo "storage permissions: matrix intact across ${#branches[@]} branches"
  exit 0
fi

echo "storage permissions: ${total} deviations"
printf '%s' "$findings"
[ "$mode" = apply ] && { echo "repaired."; exit 0; }
[ "$mode" = metrics ] && exit 0
exit 1
