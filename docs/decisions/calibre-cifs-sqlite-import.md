# Calibre Auto-Import: Working Around SQLite-on-CIFS Locking

## Context

LXC220 runs Calibre-Web against a library whose `metadata.db` (a SQLite
database) lives on the SMB/CIFS Books share served by VM102. The auto-import job
(`calibre-importer` role, see [Calibre-Web service doc](../services/calibre-web.md#auto-import))
needs to run `calibredb add` to insert dropped ebooks into that library.

`calibredb add` fails on the CIFS-hosted DB:

```
apsw.BusyError: BusyError: database is locked
  File ".../calibre/db/schema_upgrades.py", line 18, in __init__
    db.execute('BEGIN EXCLUSIVE TRANSACTION')
```

The failure persists **even with the `calibre-web` container stopped** — so it is
not process contention.

### Root cause

SQLite coordinates access with POSIX advisory **byte-range locks** (`fcntl`
`F_SETLK` on offsets inside the DB file). The Linux CIFS client translates these
into **mandatory SMB locks**, and most SMB servers do not honor the advisory
semantics SQLite expects. The lock **acquisition itself** is refused over CIFS →
`database is locked`. This is a filesystem-layer limitation, not contention.

Proven by a control test (same binary, same DB, only the filesystem differs):

- `calibredb add --with-library /books-rw …` (CIFS) → `BusyError`
- `calibredb add --with-library /tmp/lib …` (local copy of `metadata.db`) → `Added book ids: …`

### Operational constraints

- The MergerFS pool on VM102 is the **only** large storage; LXC220's root disk is
  8 GB. The book files cannot live locally.
- Calibre couples `metadata.db` to its library directory — the DB cannot be
  trivially relocated away from the book files.
- Single operator, single host writes the library, infrequent imports.

---

## Decision

Keep `metadata.db` on CIFS, but **never let SQLite open the CIFS copy**. The
import job operates on a local snapshot and writes results back with lock-free
file operations:

```
stop calibre-web                       # consistent DB snapshot, no concurrent writer
cp  metadata.db  →  /tmp/work/          # local working library (local disk, not CIFS)
calibredb add --with-library /tmp/work  # SQLite only ever touches the LOCAL file
tar new book dirs  /tmp/work → /books-rw # plain copy: no byte-range locks
atomic swap: cp metadata.db → .new && mv -f .new metadata.db
restart calibre-web                     # guaranteed via EXIT trap
```

Book files are written **before** the DB is swapped in (so the DB never
references missing files). The DB swap is a write-then-rename, so a reader never
sees a half-written file. Calibre stores book paths **relative** to the library
root, so a DB built against `/tmp/work` resolves correctly at `/books-rw`.

The full implementation is `snippets/scripts/calibre-import.sh`.

---

## Alternatives Considered

### `nobrl` mount option (rejected)

Adding `nobrl` to the CIFS mount makes the client skip byte-range lock requests
entirely, so SQLite proceeds. It is the conventional "fix" and would let the
script write straight to CIFS with no workaround.

Rejected because:

- It **disables the locking safety mechanism** — it converts a loud, safe failure
  (`database is locked` → import aborts, file is quarantined) into a silent risk
  (DB corruption the moment two writers ever coincide). "Fix locking errors by
  turning locking off" is only acceptable when single-writer is *architecturally
  enforced*, not merely currently true.
- It changes the **host** mount, affecting every consumer of the Books share, for
  a problem scoped to one job.
- It requires a controlled remount on the Proxmox host while the LXC holds the
  mount open (busy-mount handling).

### Library (DB + files) on local/block storage (deferred — the "correct" fix)

The professional default is to separate **state** (the DB — small, lock-sensitive,
belongs on local/block storage with working locks and proper backups) from
**bulk data** (the book files — large, belongs on the share). The problem then
disappears: `calibredb` runs locally with real locks.

Deferred because the book files have nowhere else to live (the MergerFS pool is
the only large store, LXC220 root is 8 GB) and Calibre couples the DB to the
library directory. Revisit if a dedicated block volume becomes available.

### Single-owner + API access (not applicable here)

Where multiple consumers share a database, the pattern is: one service owns the
state, others use its API/wire protocol (the reason LXC260 PostgreSQL exists).
Not applicable here — a single node already owns this library; the issue is the
DB's storage *location*, not multi-consumer access.

---

## Consequences

### Accepted

- `calibre-web` is briefly stopped during each import that has work to do
  (seconds; no downtime when the drop folder is empty).
- The import job is the **only** writer to the library besides calibre-web, and
  the two never run concurrently (calibre-web is stopped during the critical
  section; a `flock` guards against overlapping import runs). This single-writer
  invariant is what makes the local-snapshot-then-swap safe.
- Slightly more moving parts than a direct `calibredb add` (local copy, tar-back,
  atomic swap), all contained in one script with an EXIT-trap cleanup.

### Verification caveat

`calibredb list --with-library /books-rw` **also** fails the CIFS lock and prints
nothing (looks like an empty library, not an error). Always verify against a
**local copy** of `metadata.db`, never the CIFS path.

---

## Related Documents

- [Calibre-Web Service → Auto-Import](../services/calibre-web.md#auto-import)
- [LXC220 Node](../nodes/lxc220.md)
- [Storage Design](../platform/storage-design.md)
- devops-til: `storage/sqlite-on-cifs-locking.md` (the transferable concept)
