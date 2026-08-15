#!/usr/bin/env bash
#
# Nightly dump of the MariaDB instance on lxc210 (Nextcloud) onto the SMB backup
# share.
#
# Deployed by the mariadb_backup role. Edit this file, never the copy on the node.
#
# Why this exists at all: the nightly pg_dumpall covers lxc260 only. Nextcloud
# brings its own MariaDB, running inside lxc210, and it was never backed up --
# no role, no script, no unit, no crontab entry. Its user files live on the
# archive pool while its database lived only on the boot SSD, so losing that SSD
# left every file intact and unusable: without the database, Nextcloud's storage
# layout is opaque blobs with no owner, no name and no share.
#
# The structure deliberately mirrors snippets/postgres/pg-backup.sh, down to the
# ordering of the verification block. Where the two differ, the difference is
# commented.

set -euo pipefail

# === Configuration ===
BACKUP_DIR="/mnt/backups"
RETENTION_DAYS=7
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
DUMP_FILE="${BACKUP_DIR}/mariadb_all_${TIMESTAMP}.sql.gz"

# Written under .partial and renamed only once proven complete, so nothing ever
# selects a half-written dump as "the newest one". See pg-backup.sh for the full
# reasoning; it applies unchanged.
PARTIAL_FILE="${DUMP_FILE}.partial"

TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"

# MariaDB 10.11 ships `mariadb-dump`; `mysqldump` is a compatibility symlink that
# upstream intends to drop. Prefer the real name, fall back so the script still
# works on an older node.
DUMP_BIN="$(command -v mariadb-dump || command -v mysqldump)"

# === Pre-flight checks ===
# Test the mount's identity, not merely that the path exists. /mnt/backups is a
# bind of the host's CIFS mount. If that mount is absent the directory still
# exists and `[ -d ]` passes, so the dump would land in the container rootfs --
# i.e. in the thin pool on the boot SSD, nightly, until it fills. That is the
# KE-7 failure class and the reason this check is first.
FSTYPE="$(findmnt -no FSTYPE "$BACKUP_DIR" 2>/dev/null || true)"
if [ "$FSTYPE" != "cifs" ]; then
  echo "ERROR: ${BACKUP_DIR} is not a CIFS mount (fstype='${FSTYPE:-none}') — refusing to dump onto local disk" >&2
  exit 1
fi

# === Dump every database, plus users and grants ===
#
# --all-databases       includes the `mysql` database, so users and grants come
#                       back with the data. This is the analogue of pg_dumpall
#                       carrying roles; a data-only dump would restore into an
#                       instance nobody can log into.
# --single-transaction  takes the snapshot inside one consistent read view
#                       instead of locking the tables. Verified on this node:
#                       all 179 nextcloud tables are InnoDB, so the snapshot is
#                       genuinely consistent. The non-transactional system tables
#                       in `mysql` are not covered by it -- acceptable, because
#                       they change only when an account changes.
# --quick               streams row by row rather than buffering whole tables in
#                       memory. Irrelevant at today's 38 MB, correct as it grows.
# --routines --triggers --events
#                       stored programs are schema, and a schema restored without
#                       them is a database that looks complete and misbehaves.
# --default-character-set=utf8mb4
#                       Nextcloud stores utf8mb4; connecting in another charset
#                       would silently transcode filenames on the way out.
"$DUMP_BIN" \
  --all-databases \
  --single-transaction \
  --quick \
  --routines \
  --triggers \
  --events \
  --default-character-set=utf8mb4 \
  | gzip > "$PARTIAL_FILE"

# === Verify the dump before anything depends on it ===
#
# Everything below runs *before* the retention cleanup, and that ordering is the
# point rather than a detail: no old dump may be deleted until the new one has
# been proven readable. See pg-backup.sh, where the same ordering is derived from
# the retention window being shorter than the detection window.
#
# What these checks do NOT prove: that the bytes reached vm102. The read-back is
# served from the CIFS page cache, so this establishes that the stream is
# complete and self-consistent, not that it is durable on the far side.

# 1. Non-empty.
if [ ! -s "$PARTIAL_FILE" ]; then
  echo "ERROR: dump is empty: ${PARTIAL_FILE}" >&2
  exit 1
fi

# 2. The compressed stream is intact -- gzip -t re-reads the file and verifies
#    the CRC32 and the ISIZE trailer, so truncation and bit flips both fail here.
if ! gzip -t "$PARTIAL_FILE"; then
  echo "ERROR: dump fails the gzip integrity check: ${PARTIAL_FILE}" >&2
  exit 1
fi

# 3. The dump is logically complete. gzip -t cannot see this: a dump killed
#    halfway still produces a perfectly valid gzip member of the bytes it managed
#    to emit, and a SQL file cut between two tables restores without a single
#    error into a database that is quietly missing rows.
#    mariadb-dump writes `-- Dump completed on <timestamp>` as its final line
#    unless --skip-dump-date is given, which this script deliberately does not
#    give. Verified live on lxc210 (MariaDB 10.11.14) before this check was
#    written, rather than assumed from the PostgreSQL equivalent.
#    `grep -c` reads to EOF, so no SIGPIPE against gzip under `set -o pipefail`;
#    `|| true` is for the exit status 1 that grep returns on zero matches.
MARKERS="$(gzip -cd "$PARTIAL_FILE" | grep -c '^-- Dump completed on ' || true)"
if [ "$MARKERS" -ne 1 ]; then
  echo "ERROR: dump carries ${MARKERS} completion markers, expected 1 — truncated: ${PARTIAL_FILE}" >&2
  exit 1
fi

# === Publish under the real name ===
# A failed run leaves the .partial file behind on purpose: it is evidence for
# diagnosis, it does not match the glob a recovery would select on, and it ages
# out through the retention rule below.
mv "$PARTIAL_FILE" "$DUMP_FILE"

# === Retention cleanup ===
# Both names, so failed runs cannot accumulate .partial files on the share
# forever. -maxdepth 1 and -type f keep a delete rule from ever reaching further
# than the directory it was written for.
#
# Note this is 7 *days*, not 7 dumps: `find -mtime +7` truncates age to whole
# 24-hour units and `+7` requires strictly greater, so it is effectively 8 days.
# On a host that powers down nightly, a week of downtime leaves fewer files than
# days -- the same caveat that applies to the PostgreSQL dumps.
find "$BACKUP_DIR" -maxdepth 1 -type f \
     \( -name 'mariadb_all_*.sql.gz' -o -name 'mariadb_all_*.sql.gz.partial' \) \
     -mtime "+${RETENTION_DAYS}" -delete

# === Textfile collector metric (Prometheus backup staleness alert) ===
# Only reached when the dump above passed every check, so the metric means "a
# verified dump exists", not "the script ran".
if [ -d "$TEXTFILE_DIR" ]; then
  echo "mariadb_backup_last_success_timestamp $(date +%s)" > "${TEXTFILE_DIR}/mariadb_backup.prom"
fi

# === Summary ===
SIZE="$(du -h "$DUMP_FILE" | cut -f1)"
echo "OK: ${DUMP_FILE} (${SIZE}), gzip and completion marker verified"
