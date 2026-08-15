#!/usr/bin/env bash
#
# Nightly pg_dumpall of the whole cluster onto the SMB backup share.
#
# Deployed by the postgresql_backup role. Edit this file, never the copy on the
# node. The validation counterpart is snippets/postgres/pg-restore-test.sh, which
# restores the newest dump into a throwaway cluster once a month.

set -euo pipefail

# === Configuration ===
BACKUP_DIR="/mnt/backups"
RETENTION_DAYS=7
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
DUMP_FILE="${BACKUP_DIR}/pg_dumpall_${TIMESTAMP}.sql.gz"

# The dump is written here and only renamed to DUMP_FILE once it has been read
# back and found complete. A plain `> "$DUMP_FILE"` creates the file before
# pg_dumpall has written a single byte, so an aborted run leaves a ruin under the
# real name - which pg-restore-test.sh would then select as "the newest dump" and
# a human would mistake for a backup during recovery. Verifying an artefact that
# is already visible under its final name is verification after the fact.
# Same local-write-then-atomic-swap shape as calibre-import.sh uses for
# metadata.db, one layer up.
PARTIAL_FILE="${DUMP_FILE}.partial"

TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"

# === Pre-flight checks ===
# Test the mount's identity, not merely that the path exists. /mnt/backups is a
# bind of the host's CIFS mount of //vm102/Postgres-Backups. If that mount is
# absent, the mountpoint directory still exists and `[ -d ]` passes - pg_dumpall
# would then write ~42 MB per night into the container rootfs, i.e. into the thin
# pool on the boot SSD, until it fills. That is the KE-7 failure class, and it is
# the same mistake `mountpoint -q` made in calibre-import.sh (KE-15).
FSTYPE="$(findmnt -no FSTYPE "$BACKUP_DIR" 2>/dev/null || true)"
if [ "$FSTYPE" != "cifs" ]; then
  echo "ERROR: ${BACKUP_DIR} is not a CIFS mount (fstype='${FSTYPE:-none}') - refusing to dump onto local disk" >&2
  exit 1
fi

# === Dump all databases + roles ===
pg_dumpall | gzip > "$PARTIAL_FILE"

# === Verify the dump before anything depends on it ===
#
# Everything below runs *before* the retention cleanup, and that ordering is the
# point of this section rather than a detail of it. Retention keeps 7 days; the
# monthly restore test detects a bad dump up to 31 days late. The retention
# window is shorter than the detection window, so a dump that is only checked by
# the monthly test is discovered broken at a moment when every healthy
# predecessor has already been deleted. No old dump may be removed until the new
# one has been proven readable.
#
# What these checks do NOT prove: that the bytes reached vm102. The read-back is
# served from the CIFS page cache (cache=strict), so this establishes that the
# stream we produced is complete and self-consistent, not that it is durable on
# the far side. Durability is what the monthly restore test covers, since it
# reads a dump the cache has long since forgotten.

# 1. Non-empty. Cheapest check, and the only one the script used to have.
if [ ! -s "$PARTIAL_FILE" ]; then
  echo "ERROR: dump is empty: ${PARTIAL_FILE}" >&2
  exit 1
fi

# 2. The compressed stream is intact - gzip -t re-reads the file and verifies the
#    CRC32 and the ISIZE trailer, so truncation and bit flips both fail here.
if ! gzip -t "$PARTIAL_FILE"; then
  echo "ERROR: dump fails the gzip integrity check: ${PARTIAL_FILE}" >&2
  exit 1
fi

# 3. The dump is logically complete. This is the check that matters, because
#    gzip -t cannot see it: a pg_dumpall killed halfway still produces a
#    perfectly valid gzip member of the bytes it managed to emit. Only the
#    trailer pg_dumpall writes as its final line separates finished from
#    truncated. A dump cut after the schema but before the COPY blocks restores
#    without a single error and yields empty tables.
#    `grep -c` reads to EOF, so no SIGPIPE against gzip under `set -o pipefail`;
#    `|| true` is for the exit status 1 that grep returns on zero matches.
MARKERS="$(gzip -cd "$PARTIAL_FILE" | grep -c 'PostgreSQL database cluster dump complete' || true)"
if [ "$MARKERS" -ne 1 ]; then
  echo "ERROR: dump carries ${MARKERS} completion markers, expected 1 - truncated: ${PARTIAL_FILE}" >&2
  exit 1
fi

# === Publish under the real name ===
# Rename within one directory, so the share never shows a half-written dump under
# a name anything else selects on. A failed run leaves the .partial file behind
# on purpose: it is evidence for diagnosis, it does not match the glob the
# restore test and the recovery runbook use, and it ages out through the
# retention rule below.
mv "$PARTIAL_FILE" "$DUMP_FILE"

# === Retention cleanup ===
# Both names, so failed runs cannot accumulate .partial files on the share
# forever. -maxdepth 1 and -type f keep a delete rule from ever reaching further
# than the directory it was written for.
find "$BACKUP_DIR" -maxdepth 1 -type f \
     \( -name 'pg_dumpall_*.sql.gz' -o -name 'pg_dumpall_*.sql.gz.partial' \) \
     -mtime "+${RETENTION_DAYS}" -delete

# === Textfile collector metric (Prometheus backup staleness alert) ===
# Only reached when the dump above passed every check, so the metric means "a
# verified dump exists", not "the script ran".
if [ -d "$TEXTFILE_DIR" ]; then
  echo "pg_backup_last_success_timestamp $(date +%s)" > "${TEXTFILE_DIR}/pg_backup.prom"
fi

# === Summary ===
SIZE="$(du -h "$DUMP_FILE" | cut -f1)"
echo "OK: ${DUMP_FILE} (${SIZE}), gzip and completion marker verified"
