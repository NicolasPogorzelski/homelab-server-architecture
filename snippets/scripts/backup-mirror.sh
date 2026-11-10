#!/usr/bin/env bash
#
# Monthly copy of the newest short-term backups onto the SnapRAID array.
#
# Deployed by the backup_mirror role; edit this file, never the node copy.
#
# The short-term tier (daily archives, seven days) sits on the aux-disk, a single
# disk with a known fault (KE-13). Once a month this script copies the newest
# archive of every source group into <target>/<YYYY-MM>/, checks each copy
# against the source by sha256, and keeps the newest KEEP months: one restore
# point per month on the array.
#
# Sources and target come from /etc/backup-mirror.conf, written by the role.

set -euo pipefail

CONF="/etc/backup-mirror.conf"
# shellcheck source=/dev/null
source "$CONF"
: "${TARGET:?}" "${KEEP:?}" "${TEXTFILE_DIR:?}"
PROM_FILE="${TEXTFILE_DIR}/backup-mirror.prom"

START_TS="$(date +%s)"
OK=0
BYTES=0
FILES=0

write_metrics() {
  local tmp
  mkdir -p "$TEXTFILE_DIR"
  tmp="$(mktemp "${PROM_FILE}.XXXXXX")"
  {
    echo "# HELP backup_mirror_last_run_timestamp_seconds End of the last mirror run."
    echo "# TYPE backup_mirror_last_run_timestamp_seconds gauge"
    echo "backup_mirror_last_run_timestamp_seconds $(date +%s)"
    echo "# HELP backup_mirror_last_run_success 1 if the last run copied and verified every source."
    echo "# TYPE backup_mirror_last_run_success gauge"
    echo "backup_mirror_last_run_success ${OK}"
    echo "# HELP backup_mirror_last_bytes Bytes copied by the last run."
    echo "# TYPE backup_mirror_last_bytes gauge"
    echo "backup_mirror_last_bytes ${BYTES}"
    echo "# HELP backup_mirror_last_files Files copied by the last run."
    echo "# TYPE backup_mirror_last_files gauge"
    echo "backup_mirror_last_files ${FILES}"
  } > "$tmp"
  # The success timestamp survives a failed run, so staleness is measured from
  # the last month that actually reached the array.
  if [ "$OK" -eq 1 ]; then
    echo "backup_mirror_last_success_timestamp_seconds $(date +%s)" >> "$tmp"
  elif [ -f "$PROM_FILE" ]; then
    grep '^backup_mirror_last_success_timestamp_seconds' "$PROM_FILE" >> "$tmp" || true
  fi
  chmod 0644 "$tmp"
  mv "$tmp" "$PROM_FILE"
}
trap write_metrics EXIT

# A missing mount leaves an empty directory on the local disk; copying into it
# would fill that disk and report success.
if ! mountpoint -q "$TARGET"; then
  echo "ERROR: ${TARGET} is not mounted" >&2
  exit 1
fi

MONTH="$(date +%Y-%m)"
DEST="${TARGET}/${MONTH}"
if [ -f "${DEST}/.complete" ] && [ "${1:-}" != "--force" ]; then
  echo "${MONTH} is already mirrored; --force copies it again"
  OK=1
  exit 0
fi

# Newest file per group: SOURCES lines are "label|directory|glob|group-regex".
# The regex (sed -E) extracts the group key from the file name; empty means the
# whole directory is one group, so only its newest file is taken.
declare -a PICKED=()
for line in "${SOURCES[@]}"; do
  IFS='|' read -r label dir glob regex <<< "$line"
  declare -A newest=()
  declare -A newest_ts=()
  shopt -s nullglob
  for f in "$dir"/$glob; do
    name="$(basename "$f")"
    key="all"
    [ -n "$regex" ] && key="$(sed -E "s/${regex}.*/\\1/" <<< "$name")"
    ts="$(stat -c %Y "$f")"
    if [ -z "${newest_ts[$key]:-}" ] || [ "$ts" -gt "${newest_ts[$key]}" ]; then
      newest[$key]="$f"
      newest_ts[$key]="$ts"
    fi
  done
  shopt -u nullglob
  if [ "${#newest[@]}" -eq 0 ]; then
    echo "ERROR: source ${label} has no file matching ${dir}/${glob}" >&2
    exit 1
  fi
  for key in "${!newest[@]}"; do
    PICKED+=("${label}|${newest[$key]}")
  done
  unset newest newest_ts
done

need=0
for p in "${PICKED[@]}"; do
  need=$(( need + $(stat -c %s "${p#*|}") ))
done
avail=$(( $(df --output=avail -B1 "$TARGET" | tail -1) ))
if [ "$avail" -lt $(( need + need / 10 )) ]; then
  echo "ERROR: ${TARGET} has ${avail} bytes free, the month needs ${need}" >&2
  exit 1
fi

INCOMING="${TARGET}/.incoming-${MONTH}"
rm -rf "$INCOMING"
mkdir -p "$INCOMING"
for p in "${PICKED[@]}"; do
  label="${p%%|*}"
  src="${p#*|}"
  mkdir -p "${INCOMING}/${label}"
  dst="${INCOMING}/${label}/$(basename "$src")"
  cp --preserve=timestamps "$src" "$dst"
  # Read back from the array: a read from the page cache would check the write,
  # not the disk.
  sync "$dst"
  want="$(sha256sum "$src" | cut -d' ' -f1)"
  got="$(sha256sum "$dst" | cut -d' ' -f1)"
  if [ "$want" != "$got" ]; then
    echo "ERROR: checksum mismatch for ${src}" >&2
    exit 1
  fi
  echo "${got}  ${label}/$(basename "$src")" >> "${INCOMING}/SHA256SUMS"
  BYTES=$(( BYTES + $(stat -c %s "$dst") ))
  FILES=$(( FILES + 1 ))
done

rm -rf "$DEST"
mv "$INCOMING" "$DEST"
date -Iseconds > "${DEST}/.complete"

# Only complete month directories count and only they are removed.
mapfile -t months < <(find "$TARGET" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended -regex '.*/[0-9]{4}-[0-9]{2}' \
  -exec test -f '{}/.complete' ';' -print | sort)
while [ "${#months[@]}" -gt "$KEEP" ]; do
  echo "pruning ${months[0]}"
  rm -rf -- "${months[0]}"
  months=("${months[@]:1}")
done

OK=1
echo "mirrored ${FILES} files, ${BYTES} bytes, into ${DEST} in $(( $(date +%s) - START_TS )) s"
