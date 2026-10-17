#!/usr/bin/env bash
#
# storage-permissions.sh - verify (and optionally repair) the filesystem side of
# the VM102 share model.
#
# smb.conf governs access through Samba, not what is on the disks; this checks the
# filesystem side. See docs/platform/storage-permissions.md.
#
# The check runs per branch, never against /mnt/mergerfs: MergerFS answers a stat
# from the first branch holding the path (category.search=ff), which hides
# disagreement between branches.
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
done < <(cat "$CONF" "${CONF%.conf}.local.conf" 2>/dev/null | sed 's/#.*//')

# The optional .local.conf extends the matrix with entries that are deliberately
# not carried in the public repository. Ansible never writes or removes it, so a
# tree listed only there keeps its protection without being documented publicly.

# The branch list is read from the running mergerfs instance, not a config file or
# fstab: a new disk is covered on the next run, the control file reports what is
# mounted rather than intended, and the real disk labels stay out of the repository.
branch_spec=$(getfattr --only-values -n user.mergerfs.branches "${POOL}/.mergerfs" 2>/dev/null || true)
[ -n "$branch_spec" ] || { echo "cannot read mergerfs branches from ${POOL}/.mergerfs" >&2; exit 2; }

# getfattr --only-values emits no trailing newline, and `while read` silently drops
# a final unterminated line, which would skip the last branch. `printf '%s\n'` and
# `|| [ -n "$b" ]` prevent that; the count assertion below makes any loss loud.
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

# Violations are counted per kind, not per path, to keep Prometheus series few; the
# per-path detail goes to stdout and the journal.
declare -A count=([owner]=0 [group]=0 [dir_mode]=0 [file_mode]=0 [setgid]=0)
findings=""

# find's -perm /MASK matches "any of these bits set", so a maximum mode becomes the
# mask of bits that must not appear.
forbidden() { printf '%04o' $(( 07777 & ~8#$1 )); }

for branch in "${branches[@]}"; do
  for entry in "${entries[@]}"; do
    read -r name owner group dir_max file_max want_sgid <<<"$entry"
    path="${branch}/${name}"
    [ -d "$path" ] || continue

    declare -A hit=()
    # A literal "-" leaves the owner unpinned, for a share without `force user`
    # where files belong to whichever account wrote them.
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
    # g+s, not the absolute mode: applying the maximum to a stricter directory
    # would widen access.
    [ "${hit[setgid]}" -gt 0 ] && find "$path" -type d ! -perm -g+s -exec chmod g+s {} +
  done
done

total=0
for kind in owner group dir_mode file_mode setgid; do
  total=$(( total + count[$kind] ))
done

if [ "$mode" = metrics ]; then
  mkdir -p "$TEXTFILE_DIR"
  # Temporary file and rename, so node_exporter never reads a half-written file.
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
