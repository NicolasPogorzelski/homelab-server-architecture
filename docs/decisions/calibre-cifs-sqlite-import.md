# Calibre Auto-Import Works on a Local Copy of the Library Database

## Status
Implemented 2026-06-08 by the `calibre_importer` role; the deletion order below since 2026-06-09.
Supersedes / superseded by: -.

## Context
lxc220 runs Calibre-Web against a library whose SQLite database `metadata.db` lies on the Books
share from vm102, mounted over CIFS. The auto-import job
([Calibre-Web](../services/calibre-web.md#auto-import)) has to run `calibredb add` against that
library, and it fails:

```
apsw.BusyError: BusyError: database is locked
  File ".../calibre/db/schema_upgrades.py", line 18, in __init__
    db.execute('BEGIN EXCLUSIVE TRANSACTION')
```

The error persists with the `calibre-web` container stopped, so it is not contention. SQLite
coordinates access with POSIX advisory byte-range locks (`fcntl` `F_SETLK`); the Linux CIFS client
turns them into SMB byte-range locks, which do not give SQLite the semantics it expects, and the
lock request is refused. Control test, same binary and database, only the filesystem differs:

- `calibredb add --with-library /books-rw ...` (CIFS): `BusyError`
- `calibredb add --with-library /tmp/lib ...` (local copy of `metadata.db`): `Added book ids: ...`

Constraints: the MergerFS pool on vm102 is the only large store and lxc220's root disk is 8 GB, so
the book files cannot move to the container. Calibre keeps `metadata.db` in the library directory,
so the database cannot be relocated on its own. One node writes the library and imports are rare.

## Options
- **`nobrl` on the CIFS mount.** Lost: the client stops sending byte-range locks and SQLite works,
  but a loud failure becomes silent corruption the first time two writers coincide. It also changes
  the host mount for every consumer of the share and needs a remount while the container holds it.
- **Library (database and files) on local block storage.** Deferred: the correct separation of
  state from bulk data, but there is no block volume large enough for the books. Revisit when one
  exists.
- **One owning service, others through its API.** Not applicable: one node already owns the
  library; the problem is where the database lives, not how many consumers it has.
- **Keep `metadata.db` on CIFS and never let SQLite open it there.** Chosen.

## Decision
The import job works on a local copy and writes back with operations that take no byte-range
locks. Implementation: `snippets/scripts/calibre-import.sh`, deployed by `calibre_importer`.

```
flock                                   # one import run at a time
stop calibre-web                        # no concurrent writer, consistent snapshot
cp metadata.db -> /tmp/work/            # local working library
calibredb add --with-library /tmp/work  # SQLite only touches the local file; rejects are quarantined
tar new book dirs /tmp/work -> /books-rw
cp metadata.db -> .new && mv -f .new metadata.db   # atomic swap on the share
delete the source from _import          # only now, after the write-back
restart calibre-web                     # EXIT trap
```

Book files are written before the database is swapped in, so the database never references a
missing file, and the rename means a reader never sees a half-written database. Calibre stores paths
relative to the library root, so a database built under `/tmp/work` resolves under `/books-rw`.

## Consequences
- `calibre-web` stops for a few seconds during each import that has work; an empty drop folder
  causes no stop.
- Safety rests on a single-writer invariant: the import job and Calibre-Web never run at the same
  time, and `flock` prevents overlapping imports.
- The pool keeps no second copy of an imported book, so the source in `_import` is deleted only after
  the book directories and the swapped database are on the share. An interrupted run leaves the
  sources in place; the next timer run retries them, and `calibredb --automerge ignore` keeps the
  retry idempotent.
- `calibredb list --with-library /books-rw` hits the same lock and prints nothing, which looks like
  an empty library rather than an error. Verify against a local copy of `metadata.db`.

## Related Documents
- [Calibre-Web: auto-import](../services/calibre-web.md#auto-import)
- [lxc220](../nodes/lxc220.md)
- [Storage design](../platform/storage-design.md)
