#!/usr/bin/env bash
set -euo pipefail

# Scans the "Paperless Inbox" external storage mount for all Nextcloud users
# who have one. Runs as www-data because occ requires the web server user.
# Called by a systemd timer (paperless_inbox_scan role) to keep Nextcloud's file
# cache in sync after Paperless deletes consumed files directly on the SMB share.

OCC="/var/www/nextcloud/occ"
TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
MOUNT_POINT="/Paperless Inbox"

occ() {
  su -s /bin/bash -c "php ${OCC} $*" www-data
}

# Get all Nextcloud users as a list
USERS=$(occ "user:list --output=json" | php -r '
  $data = json_decode(file_get_contents("php://stdin"), true);
  foreach (array_keys($data) as $u) { echo $u . "\n"; }
')

for USER in ${USERS}; do
  # files:scan expects the path relative to the user's root:
  #   <username>/files/<folder_name>
  SCAN_PATH="${USER}/files/Paperless Inbox"

  # Users without the folder make files:scan fail; that error is discarded, so the
  # scan alone cannot report a dead mount. The verify below does (KE-29).
  occ "files:scan '${USER}' --path='${SCAN_PATH}' 2>/dev/null" >/dev/null 2>&1 || true
done

# One series per ingest mount: 1 when Nextcloud reaches the SMB share, 0 when not.
# Labelled by mount id only; the mount's user name stays off the metrics. Written to
# a staged file in the same directory and renamed, so node_exporter never reads half.
MOUNT_IDS=$(occ "files_external:list --output=json" | php -r '
  $mp = $argv[1];
  foreach (json_decode(file_get_contents("php://stdin"), true) as $m) {
    if ($m["mount_point"] === $mp) { echo $m["mount_id"] . "\n"; }
  }
' "${MOUNT_POINT}")

STAGED="${TEXTFILE_DIR}/paperless_ingest.prom.staged"
{
  echo "# HELP paperless_ingest_storage_up Whether Nextcloud reaches the Paperless ingest share of this mount (files_external:verify)."
  echo "# TYPE paperless_ingest_storage_up gauge"
  for ID in ${MOUNT_IDS}; do
    STATUS=$(occ "files_external:verify ${ID} --output=json" 2>/dev/null | php -r '
      $v = json_decode(file_get_contents("php://stdin"), true);
      echo (is_array($v) && ($v["status"] ?? "") === "ok") ? 1 : 0;
    ' || echo 0)
    echo "paperless_ingest_storage_up{mount_id=\"${ID}\"} ${STATUS}"
  done
  echo "# HELP paperless_inbox_scan_last_run_timestamp_seconds When the inbox scan and mount check last completed."
  echo "# TYPE paperless_inbox_scan_last_run_timestamp_seconds gauge"
  echo "paperless_inbox_scan_last_run_timestamp_seconds $(date +%s)"
} > "${STAGED}"
chmod 0644 "${STAGED}"
mv "${STAGED}" "${TEXTFILE_DIR}/paperless_ingest.prom"
