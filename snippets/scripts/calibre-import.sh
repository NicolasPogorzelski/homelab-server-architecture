#!/usr/bin/env bash
#
# calibre-import.sh — auto-import dropped ebooks into the Calibre library.
#
# Deployed on LXC220 by the Ansible role `calibre-importer`, triggered by the
# systemd timer `calibre-import.timer` (polling, NOT inotify: the library is a
# CIFS network mount and inotify does not see writes made by the SMB server).
#
# CIFS / SQLite locking (the core constraint):
#   metadata.db lives on a CIFS mount (//VM102/Books). Calibre opens the DB with
#   `BEGIN EXCLUSIVE TRANSACTION`, i.e. a POSIX byte-range lock that the SMB
#   client does not translate reliably -> `apsw.BusyError: database is locked`,
#   even with calibre-web stopped. Verified: a `calibredb add` straight onto the
#   CIFS copy fails, the identical add against a LOCAL copy of metadata.db
#   succeeds. So we never let SQLite touch the CIFS file:
#     1. stop calibre-web (consistent DB snapshot + no concurrent writer)
#     2. copy metadata.db to a LOCAL working library under /tmp
#     3. `calibredb add` into the LOCAL library (book files + DB rows land there)
#     4. push the new book directories back onto the CIFS library (plain tar,
#        no byte-range locks) and atomically swap the updated metadata.db in
#     5. delete each source file ONLY now — after it is durably on the share
#     6. restart calibre-web (guaranteed via an EXIT trap)
#
# Flow: find *settled* ebooks in $IMPORT_DIR; a file that fails `calibredb add`
# is quarantined under $FAILED_DIR; a file that imports successfully is deleted
# only AFTER the new books are written back to the share (the MergerFS pool is
# near full, so we keep no second copy). If the run is interrupted before that
# write-back, the sources stay in $IMPORT_DIR and are retried on the next run
# (`calibredb --automerge ignore` makes a retry idempotent) — so a crash mid-run
# never loses a book.
#
# Paths fixed by homelab convention: the Proxmox host binds the rw CIFS mount
# (//VM102/Books) into the container as mp2 -> /books-rw.
#
set -euo pipefail

LIBRARY="/books-rw"                 # rw view of the Calibre library (metadata.db lives here, on CIFS)
IMPORT_DIR="${LIBRARY}/_import"     # drop folder: user copies new books here over SMB
FAILED_DIR="${IMPORT_DIR}/.failed"  # quarantine for files that fail to import
LOCK="/run/calibre-import.lock"     # single-instance guard
CONTAINER="calibre-web"             # docker container that holds the library open
WORK=""                             # local working library (mktemp, set below)

# Single instance only: take an exclusive lock on FD 9 or exit quietly.
exec 9>"${LOCK}"
flock -n 9 || { echo "another import run is active — exiting"; exit 0; }

# No-op if the rw mount is absent (VM102/network down) instead of erroring.
mountpoint -q "${LIBRARY}" || { echo "library mount ${LIBRARY} not present — exiting"; exit 0; }

mkdir -p "${FAILED_DIR}"

# Collect settled candidate ebooks. -mmin +1 = last modified more than 1 minute
# ago (skips files still being uploaded). NUL-delimited to survive spaces.
mapfile -d '' -t FILES < <(find "${IMPORT_DIR}" -mindepth 1 -type f \
    -regextype posix-extended -iregex '.*\.(epub|mobi|azw3|pdf|cbz|cbr)$' \
    -not -path "${FAILED_DIR}/*" -mmin +1 -print0)

# Nothing to do -> leave calibre-web running untouched (no downtime).
[ "${#FILES[@]}" -eq 0 ] && exit 0

# Local working library under /tmp (local disk, never CIFS). Cleaned up and
# calibre-web restarted on EXIT — even if the script errors out partway.
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
        # Do NOT delete the source yet — it only lives in the volatile local WORK
        # copy at this point. Track it; delete after it is written back (below).
        imported_srcs+=("${f}")
        echo "added to working library (source kept until written back): ${f}"
    else
        echo "FAILED — quarantining: ${f}"
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

    # Durable now: the books are on the share AND referenced by the swapped-in DB.
    # Only here is it safe to delete the sources (no second copy is kept). Had the
    # script died before this point, `set -e` would have aborted with the sources
    # still in $IMPORT_DIR — they would simply be retried on the next run.
    for f in "${imported_srcs[@]}"; do
        rm -f "${f}"
        echo "source removed (durably imported): ${f}"
    done
fi

# Tidy up drop subfolders that are now empty (never the quarantine dir).
find "${IMPORT_DIR}" -mindepth 1 -type d -empty -not -path "${FAILED_DIR}" -delete 2>/dev/null || true

echo "import run complete (${#imported_srcs[@]} imported)"
# calibre-web is restarted and WORK removed by the EXIT trap
