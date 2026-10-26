# Storage Permission Model (VM102)

The target state of the filesystem underneath the Samba shares, and how it is verified.

[`samba.md`](samba.md) documents what Samba enforces. The filesystem underneath:
what the objects on the disks must look like after Samba has written them, or when Samba was never
involved.

---

## Why a filesystem target is needed

Samba masks apply only when Samba creates an object, so they cannot describe what is on disk:
directories made over SSH bypass them, and older files keep their mode. A target state for the
filesystem is needed to compare against.

Verified 2026-08-16: a sweep of the MergerFS branches found objects with the wrong group and
directories without setgid. No consumer noticed, because every object also carried read
permission for `other`, and that was the path access actually took. A working service did not
distinguish the intended group path from the redundant world path. The matrix below states the
target; the [`storage_permissions`](../../ansible/roles/storage_permissions) role checks it daily.

---

## The matrix

Modes are maxima. An object violates the matrix if it carries a bit the maximum does not allow;
stricter is acceptable (a 0600 file under a 0660 allowance is not drift). The check answers one
question: can an account reach an object it should not.

| Path | Owner | Group | Directories | Files | setgid | Read path |
|---|---|---|---|---|---|---|
| `Audiobooks` | storage | media-abs | 2750 | 0640 | yes | Audiobookshelf, via group |
| `Podcasts` | storage | media-abs | 2750 | 0640 | yes | Audiobookshelf, via group |
| `Filme` | storage | media-jf | 2750 | 0640 | yes | Jellyfin, via group |
| `Serien` | storage | media-jf | 2750 | 0640 | yes | Jellyfin, via group |
| `Books` | storage | books-svc | 2750 | 0640 | yes | Calibre-Web, via group |
| `Nextcloud` | storage | storage | 2770 | 0660 | yes | owner only |
| `Paperless` | storage | storage | 2770 | 0660 | yes | owner only |
| `openwebui` | storage | storage | 2770 | 0660 | yes | owner only |
| `Postgres-Backups` | storage | storage | 2770 | 0660 | yes | owner only |
| `DB-Backups` | storage | storage | 2770 | 0660 | yes | owner only |

Two rules govern the table:

- **`other` gets nothing, anywhere.** Remaining world bits are legacy. A service that loses its
  group membership must lose access at once and visibly, instead of keeping it through a world bit
  that nobody counted on.
- **The matrix applies per branch, never to the union.** MergerFS answers a stat from the first
  branch holding the path (`category.search=ff`), so `ls /mnt/mergerfs/...` shows one disk out of
  six and hides any disagreement between them. Every check and every repair iterates branches
  directly.

### Why the owner is `storage` and not the service

Service accounts do not own their data. They read it as group members, and the shares carry
`force user = storage` so that writes land as `storage` regardless of who connects.

Whoever owns a file may always change its permissions, whatever the mode says, so an account owning the media library could grant itself write access to a share the model
declares read-only. Keeping ownership at `storage` and giving the consumer group read access
removes that possibility.

A share without `force user` is the exception: its files legitimately belong to whichever account
wrote them, so the owner column is left unpinned there; pinning it would produce a violation count
that never reaches zero.

---

## Configuration Management

Owned by the [`storage_permissions`](../../ansible/roles/storage_permissions) role, applied with
`ansible-playbook playbooks/storage-permissions.yml`. It deploys:

- `/usr/local/sbin/storage-permissions.sh` - the check, from
  [`snippets/storage/storage-permissions.sh`](../../snippets/storage/storage-permissions.sh)
- `/etc/storage-permissions.conf` - the matrix above, rendered from the role's `defaults/main.yml`
- optionally `/etc/storage-permissions.local.conf` - additional entries kept off the repository;
  the script reads it alongside the managed file and Ansible neither writes nor removes it
- `storage-permissions.timer` - daily, `Persistent=true`, before the nightly power-off (schedule in
  the role defaults; the shutdown script waits for it)
- every share directory of the matrix on every branch, created with its owner, group and directory
  mode where the branch does not have it yet; existing directories are left as they are

Pre-creating the share directories is necessary because MergerFS places a new file on the branch
with the most free space (`category.create=mfs`) and, if the share does not exist there, recreates
its directory with `mkdir`, which keeps only the `0777` bits and sets setgid only under a setgid
parent (`man 2 mkdir`); a branch root has none. With every share present on every branch there is
nothing left to recreate, and subdirectories inherit setgid from their share.

The branch list is not kept in the repository. The script reads it from the running MergerFS
instance (`user.mergerfs.branches` on the pool's control file), for three reasons: a disk added to
the pool is covered on the next run without editing anything; the control file reports what is
mounted, which can differ from what fstab intended; and the real disk labels stay out of version control
(enforced by the repository validator).

### Modes

```bash
storage-permissions.sh --check     # report deviations, exit 1 if any (default)
storage-permissions.sh --apply     # repair them
storage-permissions.sh --metrics   # write the node_exporter textfile metric, always exit 0
```

`--metrics` exits 0 even when the matrix is violated, so that drift is reported by Prometheus and
a failed unit means the check itself could not run.

---

## Verification

```bash
# on vm102
/usr/local/sbin/storage-permissions.sh --check

# what the consumers can actually reach - the test that matters
for u in media-jf media-abs books-svc; do
  printf '%-10s: ' "$u"
  for d in Filme Serien Audiobooks Podcasts Books openwebui; do
    runuser -u "$u" -- ls "/mnt/mergerfs/$d" >/dev/null 2>&1 && printf '%s ' "$d"
  done
  echo
done
```

Expected: each account sees its own libraries and nothing else.

The stronger test is the negative one: a positive result confirms every redundant path along with
the intended one. To prove the group is load-bearing, remove the world bits from a copy and
confirm access continues.

---

## Monitoring

| Rule | Fires when |
|---|---|
| `StoragePermissionDrift` | `sum(storage_permission_violations) > 0` for 1h |
| `StoragePermissionCheckStale` | no completed check for 48h |

Both live in [`alert.rules.yml`](../../docker/monitoring/prometheus/rules/alert.rules.yml). The
staleness rule is required: the textfile metric holds its last value indefinitely, so a check that
stops running keeps reporting its last pass.

---

## Failure Impact

A violated matrix weakens a boundary and breaks nothing: consumers keep working, so only the alert
reveals it. The realistic damage path is a service account reading data outside its own library.

---

## Out of scope

- **Share scope.** Each consumer share is scoped to one library; that is Samba's half of the
  boundary ([samba.md](samba.md)).
- **`smb.conf` itself.** The four workstation shares carry `create mask = 0640` and
  `directory mask = 2750` so that new content is born compliant, but the role verifies the result
  on disk. Masks govern one of three ways an object comes into being; a check that trusted them
  would miss the other two.

---

## Related

- [Samba architecture](samba.md) - the share model and what Samba enforces
- [Storage design](storage-design.md) - MergerFS, SnapRAID, the pool layout
- [VM102 node documentation](../nodes/vm102.md)
- [Known errors](known-errors.md) - KE-13 and KE-19 for the same failure class in other layers
