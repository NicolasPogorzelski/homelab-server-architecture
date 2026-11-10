# Media Ingest Never Adds a Duplicate and Replaces Only Through Quarantine

## Status
Proposed 2026-11-02. Supersedes / superseded by: -. Amends
[media-ingest-pipeline.md](media-ingest-pipeline.md).

## Context
`Ingest/` on the admin desktop collects files from several sources over time, and the libraries
are large enough that it is not obvious by hand whether an item is already present. A second copy
in a library costs pool space and parity time and appears twice in the client apps.

Verified 2026-11-02: `Ingest/` held items already in Audiobookshelf and Jellyfin and items twice
inside `Ingest/`, by a stage 1 prototype comparing `find -printf` sizes from the desktop with
read-only snapshots of both service databases.

Both databases hold the fields a quality comparison needs, so the comparison reads no library
file. Jellyfin `MediaStreamInfos`: resolution, HDR and Dolby Vision flags, codec, bit rate,
channels, language. Audiobookshelf `books`: `abridged`, `duration`, and per file codec and bit rate.

The pipeline ADR rules out any deletion or replacement in a library by the pipeline.

## Options
- **Skip the duplicate, keep the source.** `Ingest/` keeps growing and the next run reports the
  same items again.
- **Replace the library copy in place.** A wrong quality verdict destroys the better copy; parity
  holds it only until the next sync.
- **Remove expired quarantine with a root timer.** An automated process would delete library
  content again.
- **Delete the duplicate source; replace only through a quarantine folder after approval.** Chosen.

## Decision
Stage 1 matches every item against the target library and against the rest of `Ingest/`. A match
changes a library only as an approved upgrade.

| Match | Verdict | Source on the desktop |
|---|---|---|
| Bit-identical (same size, same SHA-256) | `skip-duplicate` | deleted by the run |
| Same work, equal or lower quality | `skip-duplicate` | deleted after approval in the review file |
| Same work, higher quality | `review` (upgrade) | applied after approval, then deleted |
| Same files twice inside `Ingest/` | `skip-duplicate` for every copy but one | deleted by the run |

A non-identical match waits for approval because the work is identified from names and
metadata, which can be wrong.

Quality is compared field by field in a fixed order; the first field that differs decides. Bit
rate decides only on a clear step, such as a remux against an encode:

- **Video:** German audio track present; resolution; HDR (Dolby Vision > HDR10+ > HDR10 > SDR);
  remux before encode; audio format (Atmos, TrueHD, DTS:X > DTS-HD > AC3).
- **Audiobook:** unabridged before abridged; a runtime more than 2 % apart is a different
  edition and goes to `review`; bit rate.

An approved upgrade is applied by `ingest-finalize`: it moves the library copy to
`<library>/.replaced/<run>/` and then the new item into place, both with `RENAME_NOREPLACE`, and
logs both moves for the undo script. After 30 days the run's quarantine appears on a deletion
list in the review file; a person deletes it as the break-glass `storage` account.

## Consequences
- The desktop key needs a forced command that serves read-only `rsync --sender` and deletes only
  regular files below `Ingest/` that the run listed, after rechecking each file's size and hash.
- Stage 1 hashes every candidate that matches by size, which reads it once on the desktop.
- Items in `Ingest/` whose library match has not been scanned yet are missed by the database
  snapshot; stage 1 also compares the top-level folder names of the film and series libraries.
- `.replaced/` is skipped by `storage-permissions.sh` like `.ingest/`, and Jellyfin and
  Audiobookshelf ignore it as a hidden folder. It occupies pool space for up to 30 days per
  upgrade and is covered by parity like any other folder.
- The `ingest` account cannot delete or overwrite anything in a library; the quarantine move
  is the one new step of the root program.
