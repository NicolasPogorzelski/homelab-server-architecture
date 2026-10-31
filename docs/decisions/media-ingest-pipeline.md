# Media Ingest Runs as a Reviewed Pipeline on Its Own Container (lxc221)

## Status
Proposed 2026-10-28. Supersedes / superseded by: -.

## Context
New media reach Calibre, Audiobookshelf and Jellyfin by hand; Navidrome is planned. The work splits
into two kinds:

- **Mechanical:** hashes, format, word count, comparison with the library database, packaging,
  read-back.
- **Reading text:** title, author and series from inconsistent file names and embedded metadata;
  original titles, translators and omnibus contents from the imprint; authors from PDF title pages.
  File names and embedded metadata truncate or omit these fields, so a value read without its
  source text can be wrong.

Verified 2026-10-28: abridged editions had 15 to 32 % fewer words than the complete edition of the
same title, by counting the words of the EPUB text documents of both.

Edition rules: one file per book; EPUB, then AZW3, MOBI, PDF; never an abridged text; an omnibus
edition when it completes a series; an English edition only without a German one.

Constraints:

- Files arrive in `Ingest/<type>/` (`Filme`, `Serien`, `Audiobooks`, `E-Books`) on a data drive of
  the admin desktop, which is often off.
- The files are untrusted input, and the extraction step feeds their text to an LLM.
- Automated requests go to the vm100 inference instance only
  ([LLM inference](../services/llm-inference.md#known-issues)).
- `metadata.db` cannot be written over CIFS ([KE-1](../platform/known-errors.md#ke-1)).
- Audiobookshelf does not watch its library, so its `POST /api/watcher/update` cannot add single
  paths. Verified 2026-10-28: `[Server] Watcher is disabled` in the container log.
- The `scratch` pool is not overcommitted ([scratch pool](scratch-pool-on-former-boot-ssd.md)).
  Verified 2026-10-28: 32 GiB of 104 GiB allocated, by `lvs scratch`.

## Options
- **Desktop timer.** The files are local, but the desktop would hold write access to every library
  and root on lxc220, outside Ansible, and run only while it is on.
- **Job on lxc250.** A parser of untrusted files would run with the Ansible key.
- **Unreviewed apply.** A misread author or an abridged edition reaches the library unseen.
- **Staging every medium on `scratch`.** Film and series batches exceed the pool.
- **Straight copy into the library folders.** An aborted run leaves partial files among existing
  items, and a scan during the copy picks up half an item.
- **Dedicated container with a reviewed pipeline and a hidden landing folder.** Chosen: the desktop
  gets no write access, the parser never holds the Ansible key, and only Calibre and music use
  `scratch`.

## Decision
lxc221, an unprivileged Debian LXC in the media range with its own tag `tag:ingest`, runs the
pipeline. A deterministic core does everything that can be measured; the LLM proposes field values,
each with a verbatim quote that a check must find in the source text. The stage 3 rules set each
item to `auto`, `review` or `skip`; the stage 7 deletion is run by a person.

| Stage | Work | Where |
|---|---|---|
| 1 Inventory | hash, format, word count or duration, imprint text, match against the library | at the source, over SSH |
| 2 Extraction | LLM returns JSON per field with its quote; an unmatched quote leaves the field open | lxc221 |
| 3 Rules | each item becomes `auto`, `review` or `skip` with its reason | lxc221 |
| 4 Approval | review file `Ingest/_review/<run>.md`; later a tailnet-only page on lxc221 that reads the same format | admin desktop |
| 5 Apply | packages through the adapter of the media type | see below |
| 6 Read-back | hashes in the target, database state, `storage-permissions.sh --check`, service answers | lxc221 |
| 7 Deletion list | written for the source; executed by a person | admin desktop |

Two run modes:

- **Timer run:** LLM on vm100; the schedule belongs to the lxc221 role's defaults. Items that pass
  every rule with every field quoted are applied, all others wait in the review file. A run missed
  while the desktop is off waits for its next start.
- **Manual run:** LLM on the desktop instance, falling back to vm100 when it does not answer; every
  item waits for approval.

| Adapter | Apply | Made visible by |
|---|---|---|
| E-Books -> Calibre | `calibre-debug` against a local copy of `metadata.db` in staging, holding `/run/calibre-import.lock`; the database is swapped only if the live hash is unchanged | calibre-web restart |
| Audiobooks -> Audiobookshelf | stream to `.ingest/<run>/` in the library root on vm102, verify, fix permissions, rename into place | library scan through the API |
| Filme, Serien -> Jellyfin | same as Audiobookshelf | library scan through the API |
| Music -> Navidrome (planned) | staging, because tagging rewrites the files | scan through the API |

The root filesystem is on `local-lvm`. A 20 GiB thin volume on `scratch` with `discard=on` and
`fstrim.timer` holds staging for Calibre and music; audiobooks, films and series stream from the
desktop through lxc221 to vm102 without staging.

Each step gets the least access it needs: read-only SSH to the desktop's `Ingest/`, a
forced-command key on lxc220 that runs the Calibre apply script only, write access to the library
roots on vm102, and API keys for the scans and for both inference instances on port 8080. Grants
live in [tailscale-acl.md](../platform/tailscale-acl.md).

## Consequences
- A new node with its own document, tag, grants and secrets.
- Writes to vm102 need an identity that is still to be designed: files must land as
  `storage:<media group>`, and the `storage` login holds sudo, so its key is too broad for this job.
- `rename` from `.ingest/` into place does not return `EXDEV` on this pool. Verified 2026-10-31
  on mergerfs 2.33.5 (`func.rename=epall`, `category.create=mfs`) as `storage`: a file and a
  directory staged on disk06 were renamed into an author directory that existed only on disk03;
  mergerfs cloned the author path onto disk06 and renamed there. A book stays on the disk `mfs`
  chose for its staging folder, its author directory spreads over two disks, and the clone stays
  behind empty if the book is removed again.
- The smaller model of the timer run sends more items to review; only items whose every field is
  quoted are applied.
- Library content appears in the review file, which stays on the desktop and never enters the
  repository.
- `calibre_importer` stays as a fallback path into Calibre that skips every rule; keeping or
  retiring it is decided again after several successful pipeline runs.
- With the staging volume, `scratch` has 52 GiB left for disposable guests.
