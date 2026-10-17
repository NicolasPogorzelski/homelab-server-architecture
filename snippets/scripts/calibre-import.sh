#!/usr/bin/env bash
#
# calibre-import.sh - auto-import dropped ebooks into the Calibre library.
#
# Deployed on lxc220 by the calibre_importer role, run by calibre-import.timer
# (polling: inotify does not see writes made by the SMB server).
#
# SQLite byte-range locks fail on CIFS ("database is locked"), so metadata.db is
# never written in place (KE-1, docs/decisions/calibre-cifs-sqlite-import.md):
#   1. stop calibre-web, copy metadata.db to a local working library under /tmp
#   2. `calibredb add` into the local library
#   3. tar the new book directories back to the share, swap metadata.db in
#   4. only then delete the sources; calibre-web restarts from an EXIT trap
# Files that fail to import are quarantined in $FAILED_DIR. An interrupted run
# leaves the sources in $IMPORT_DIR for the next run (--automerge ignore keeps
# the retry idempotent). The host binds //VM102/Books into the container as
# mp2 -> /books-rw.
set -euo pipefail

LIBRARY="/books-rw"                 # rw view of the Calibre library (metadata.db lives here, on CIFS)
IMPORT_DIR="${LIBRARY}/_import"     # drop folder: user copies new books here over SMB
FAILED_DIR="${IMPORT_DIR}/.failed"  # quarantine for files that fail to import
LOCK="/run/calibre-import.lock"     # single-instance guard
CONTAINER="calibre-web"             # docker container that holds the library open
WORK=""                             # local working library (mktemp, set below)

# Single instance only: take an exclusive lock on FD 9 or exit quietly.
exec 9>"${LOCK}"
flock -n 9 || { echo "another import run is active - exiting"; exit 0; }

# Test the mount's identity, not its existence: the mp2 bind is a mountpoint even
# when the host-side CIFS mount failed, and then shows an empty ext4 directory on
# pve-root. A healthy bind reports fstype `cifs`. See KE-15.
fstype="$(findmnt -no FSTYPE "${LIBRARY}" 2>/dev/null || true)"
if [ "${fstype}" != "cifs" ]; then
    echo "library ${LIBRARY} is not a CIFS mount (fstype='${fstype:-none}') - host share not mounted" >&2
    exit 1
fi

# Second guard: right filesystem type, wrong share. Without metadata.db this is not
# the Calibre library, and importing into it would scatter books into a stray mount.
if [ ! -f "${LIBRARY}/metadata.db" ]; then
    echo "library ${LIBRARY} has no metadata.db - refusing to import" >&2
    exit 1
fi

mkdir -p "${FAILED_DIR}"

# Collect settled candidate ebooks. -mmin +1 = last modified more than 1 minute
# ago (skips files still being uploaded). NUL-delimited to survive spaces.
mapfile -d '' -t FILES < <(find "${IMPORT_DIR}" -mindepth 1 -type f \
    -regextype posix-extended -iregex '.*\.(epub|mobi|azw3|pdf|cbz|cbr)$' \
    -not -path "${FAILED_DIR}/*" -mmin +1 -print0)

# Nothing to do -> leave calibre-web running untouched (no downtime).
[ "${#FILES[@]}" -eq 0 ] && exit 0

# Local working library under /tmp (local disk, never CIFS). Cleaned up and
# calibre-web restarted on EXIT - even if the script errors out partway.
WORK="$(mktemp -d /tmp/calibre-import.XXXXXX)"
cleanup() {
    docker start "${CONTAINER}" >/dev/null 2>&1 || true   # no-op if already running
    rm -rf "${WORK}"
}
trap cleanup EXIT

# Stop calibre-web: gives a consistent metadata.db snapshot and removes the only
# other writer before we swap the DB back in.
echo "stopping ${CONTAINER} to import ${#FILES[@]} file(s)"
docker stop "${CONTAINER}" >/dev/null

# Snapshot the live DB into the local working library.
cp "${LIBRARY}/metadata.db" "${WORK}/metadata.db"

# Successfully-added source paths, deleted only after the durable write-back.
imported_srcs=()
for f in "${FILES[@]}"; do
    echo "importing: ${f}"
    if calibredb add --with-library "${WORK}" --automerge ignore "${f}"; then
        # Do NOT delete the source yet - it only lives in the volatile local WORK
        # copy at this point. Track it; delete after it is written back (below).
        imported_srcs+=("${f}")
        echo "added to working library (source kept until written back): ${f}"
    else
        echo "FAILED - quarantining: ${f}"
        mv -f "${f}" "${FAILED_DIR}/"
    fi
done

# Push results back to the CIFS library only if something was actually added.
if [ "${#imported_srcs[@]}" -gt 0 ]; then
    # New book directories (everything in WORK except the DB and its journals).
    # tar uses no byte-range locks, so CIFS is happy; extracting merges into any
    # existing author directories. Book files must land BEFORE the DB references them.
    echo "writing ${#imported_srcs[@]} new book file(s) back to ${LIBRARY}"
    tar -C "${WORK}" --exclude='metadata.db*' -cf - . | tar -C "${LIBRARY}" -xf -

    # Atomically swap the updated metadata.db in (write-then-rename on the share).
    cp "${WORK}/metadata.db" "${LIBRARY}/.metadata.db.new"
    mv -f "${LIBRARY}/.metadata.db.new" "${LIBRARY}/metadata.db"

    # Durable now: the books are on the share and referenced by the swapped-in DB,
    # so the sources can go (no second copy is kept).
    for f in "${imported_srcs[@]}"; do
        rm -f "${f}"
        echo "source removed (durably imported): ${f}"
    done
fi

# Tidy up drop subfolders that are now empty (never the quarantine dir).
find "${IMPORT_DIR}" -mindepth 1 -type d -empty -not -path "${FAILED_DIR}" -delete 2>/dev/null || true

echo "import run complete (${#imported_srcs[@]} imported)"
# calibre-web is restarted and WORK removed by the EXIT trap
