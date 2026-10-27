#!/usr/bin/env bash
#
# Daily application backups on vm100: Jellyfin through its backup API, and a
# freshness check of the archive Audiobookshelf writes on its own schedule.
#
# Deployed by the app_backup role; edit this file, never the node copy.
#
# Both archives land under /mnt/vm-data, the data disk on the aux-disk, which the
# guest backup skips (backup=0). backup_mirror copies the newest of each to the
# array once a month. Jellyfin's archive holds the database and the subtitles;
# metadata images and trickplay are rebuilt from the media and stay out.

set -euo pipefail

ENV_FILE="/etc/app-backup.env"
# shellcheck source=/dev/null
source "$ENV_FILE"
: "${JELLYFIN_ENV:?}" "${JELLYFIN_API_KEY:?}" "${JELLYFIN_BACKUP_DIR:?}" "${JELLYFIN_KEEP:?}"
: "${ABS_BACKUP_DIR:?}" "${TEXTFILE_DIR:?}"
PROM_FILE="${TEXTFILE_DIR}/app-backup.prom"

JF_OK=0

newest_mtime() {  # $1 = directory, $2 = glob; prints 0 when nothing matches
  local f t=0
  shopt -s nullglob
  for f in "$1"/$2; do
    [ "$(stat -c %Y "$f")" -gt "$t" ] && t="$(stat -c %Y "$f")"
  done
  shopt -u nullglob
  echo "$t"
}

write_metrics() {
  local tmp
  mkdir -p "$TEXTFILE_DIR"
  tmp="$(mktemp "${PROM_FILE}.XXXXXX")"
  {
    echo "# HELP app_backup_last_archive_timestamp_seconds Modification time of the newest archive per application."
    echo "# TYPE app_backup_last_archive_timestamp_seconds gauge"
    echo "app_backup_last_archive_timestamp_seconds{app=\"jellyfin\"} $(newest_mtime "$JELLYFIN_BACKUP_DIR" '*.zip')"
    echo "app_backup_last_archive_timestamp_seconds{app=\"audiobookshelf\"} $(newest_mtime "$ABS_BACKUP_DIR" '*.audiobookshelf')"
    echo "# HELP app_backup_last_run_success 1 if the last run created and found the Jellyfin archive."
    echo "# TYPE app_backup_last_run_success gauge"
    echo "app_backup_last_run_success ${JF_OK}"
  } > "$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$PROM_FILE"
}
trap write_metrics EXIT

# Jellyfin publishes on the address its Compose stack binds (KE-28); reading it
# from that .env keeps the address in one place.
JF_ADDR="$(sed -n 's/^JELLYFIN_BIND_ADDR=//p' "$JELLYFIN_ENV")"
: "${JF_ADDR:?JELLYFIN_BIND_ADDR missing in ${JELLYFIN_ENV}}"

before="$(newest_mtime "$JELLYFIN_BACKUP_DIR" '*.zip')"
# The call returns when the archive is written. The key goes in a header read
# from a file descriptor, so it never appears in the process list.
curl -fsS --max-time 3600 -X POST "http://${JF_ADDR}:8096/Backup/Create" \
  -H @<(printf 'Authorization: MediaBrowser Token="%s"\n' "$JELLYFIN_API_KEY") \
  -H 'Content-Type: application/json' \
  -d '{"Database":true,"Subtitles":true,"Metadata":false,"Trickplay":false}' > /dev/null
after="$(newest_mtime "$JELLYFIN_BACKUP_DIR" '*.zip')"
if [ "$after" -le "$before" ]; then
  echo "ERROR: Jellyfin reported success but no new archive appeared in ${JELLYFIN_BACKUP_DIR}" >&2
  exit 1
fi

# Jellyfin keeps every archive; the oldest beyond JELLYFIN_KEEP are removed.
mapfile -t archives < <(ls -1t "$JELLYFIN_BACKUP_DIR"/*.zip)
for old in "${archives[@]:$JELLYFIN_KEEP}"; do
  echo "pruning ${old}"
  rm -f -- "$old"
done

JF_OK=1
echo "jellyfin archive written; keeping ${JELLYFIN_KEEP}"
