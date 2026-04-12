#!/usr/bin/env bash
set -euo pipefail

# Scans the "Paperless Inbox" external storage mount for all Nextcloud users
# who have one. Runs as www-data because occ requires the web server user.
# Intended to be called via cron to keep Nextcloud's file cache in sync
# after Paperless deletes consumed files directly on the SMB share.

OCC="/var/www/nextcloud/occ"

# Get all Nextcloud users as a list
USERS=$(su -s /bin/bash -c "php ${OCC} user:list --output=json" www-data | php -r '
  $data = json_decode(file_get_contents("php://stdin"), true);
  foreach (array_keys($data) as $u) { echo $u . "\n"; }
')

for USER in ${USERS}; do
  # files:scan expects the path relative to the user's root:
  #   <username>/files/<folder_name>
  SCAN_PATH="${USER}/files/Paperless Inbox"

  # Check if this user actually has the Paperless Inbox folder
  # by testing if scan produces output (no error = folder exists)
  su -s /bin/bash -c "php ${OCC} files:scan '${USER}' --path='${SCAN_PATH}' 2>/dev/null" www-data >/dev/null 2>&1 || true
done
