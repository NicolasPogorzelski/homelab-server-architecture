# Storage Permission Model (VM102)

The target state of the filesystem underneath the Samba shares, and how it is verified.

[`samba.md`](samba.md) documents what Samba enforces. This document covers the other half: what
the objects on the disks are supposed to look like once Samba is done with them, or when Samba was
never involved at all.

---

## Why this document exists

On 2026-08-16 a sweep of the MergerFS branches found objects carrying the wrong group, and several
directories missing their setgid bit. No consumer was affected. Jellyfin, Audiobookshelf and
Calibre-Web read their libraries throughout.

They were not reading through their groups. Every object also carried read permission for `other`,
and that is the path access actually took. Nothing could detect this, because the only observable
signal - whether the service works - stayed green.

Dating it: the pool and all six branches were created on 26 December 2025, so the model had been
in this state for a little under eight months. The wrong groups themselves are younger. MergerFS
places new writes on the branch with the most free space, so the aux branch only started receiving
content once the larger disks filled up, and its oldest media directory dates from 2026-05-07.
`Books` is the older half of the finding: it was never assigned to its service group at all, from
the day the pool was built.

Three things had to be true at once for that to happen. Each is a class rather than an incident:

1. **A second mechanism did the job of the first.** As long as the permission bits for `other`
   were open, group membership never had to be correct, and no observation distinguished the two
   cases. `smart_health_passed` reporting PASSED over 7680 unreadable sectors
   ([KE-13](known-errors.md#ke-13)) is the same problem in a different layer.
2. **The enforcement point and the objects did not overlap.** `create mask` in `smb.conf` applies
   when Samba creates a file, and never afterwards. Directories made over SSH bypass it entirely,
   which is how five top-level directories came to be mode 0755. Files predating a mask keep their
   old mode forever, which is why Vaultwarden still held 0644 private keys from January under a
   0660 mask set in spring.
3. **Nothing stated the target state, so nothing could be compared against it.** The share
   configuration was documented in three places. The filesystem was documented nowhere.

This file addresses the third point; the [`storage_permissions`](../../ansible/roles/storage_permissions)
role checks the result daily so it does not drift back.

---

## The matrix

Modes are read as maxima rather than as exact values. An object violates the matrix if it carries a bit the
maximum does not allow. Stricter is always acceptable - that is what lets Vaultwarden keep its
private keys at 0600 under a 0660 allowance without being reported as drift, and it keeps the check
answering the question that matters ("can anyone reach this who should not") rather than enforcing
cosmetic uniformity.

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
| `Vaultwarden` | storage | storage | 0770 | 0660, keys 0600 | no | owner only |

Two rules govern the table:

- **`other` gets nothing, anywhere.** Where world bits still exist they are legacy, not intent. A
  service that loses its group membership must lose access immediately and visibly, rather than
  falling through to a second mechanism nobody knew was load-bearing.
- **The matrix applies per branch, never to the union.** MergerFS answers a stat from the first
  branch holding the path (`category.search=ff`), so `ls /mnt/mergerfs/...` shows one disk out of
  six and hides any disagreement between them. Every check and every repair iterates branches
  directly. The branch whose missing setgid bit caused the finding was the sixth of six, and the
  union view never displayed it.

### Why the owner is `storage` and not the service

Service accounts do not own their data. They read it as group members, and the shares carry
`force user = storage` so that writes land as `storage` regardless of who connects.

That is deliberate. Whoever owns a file may always change its permissions, whatever the mode
says, so an account owning the media library could grant itself write access to a share the model
declares read-only. Keeping ownership at `storage` and giving the consumer group read access
removes that possibility.

A share without `force user` is the exception: its files legitimately belong to whichever account
wrote them, so the owner column is left unpinned there. Pinning it would produce a violation count
that never reaches zero, for the same reason `DiskSpaceCritical` was rewritten in July 2026.

---

## Configuration Management

Owned by the [`storage_permissions`](../../ansible/roles/storage_permissions) role, applied with
`ansible-playbook playbooks/storage-permissions.yml`. It deploys:

- `/usr/local/sbin/storage-permissions.sh` - the check, from
  [`snippets/storage/storage-permissions.sh`](../../snippets/storage/storage-permissions.sh)
- `/etc/storage-permissions.conf` - the matrix above, rendered from the role's `defaults/main.yml`
- optionally `/etc/storage-permissions.local.conf` - additional entries kept off the repository;
  the script reads it alongside the managed file and Ansible neither writes nor removes it
- `storage-permissions.timer` - daily at 23:30, `Persistent=true`

The branch list is not kept in the repository. The script reads it from the running MergerFS
instance (`user.mergerfs.branches` on the pool's control file), for three reasons: a disk added to
the pool is covered on the next run without editing anything; the control file reports what is
mounted rather than what fstab intended; and the real disk labels are kept out of version control
by `validate-repo.sh` Check 18.

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

The stronger test is the negative one. A positive result confirms every redundant path along with
the intended one, which is exactly how this defect survived. To prove the group is load-bearing,
remove the world bits from a copy and confirm access continues.

---

## Monitoring

| Rule | Fires when |
|---|---|
| `StoragePermissionDrift` | `sum(storage_permission_violations) > 0` for 1h |
| `StoragePermissionCheckStale` | no completed check for 48h |

Both live in [`alert.rules.yml`](../../docker/monitoring/prometheus/rules/alert.rules.yml). The
staleness rule is not optional: a check that stops running looks exactly like a check that keeps
passing, because the textfile metric holds its last value indefinitely.

---

## Failure Impact

A violated matrix is a weakened boundary, not an outage. Consumers keep working - that is precisely
the problem, and the reason this is monitored rather than left to be noticed.

The realistic damage path is a service account reading data outside its own library. Before
2026-08-16 that was live: Jellyfin's and Audiobookshelf's accounts could read `Books` and `openwebui`,
because both held read-only shares scoped to the entire pool rather than to their libraries. Their containers only ever received their own directories, which limited the
blast radius by accident rather than by design.

---

## Deliberately out of scope

- **Share scope - done 2026-08-16.** `[media-jf]` and `[media-abs]` exported the whole pool and
  were replaced by four scoped shares, one per library. The change avoided unmounting anything on
  a running VM100: new mount units on new paths, the two `.env` files repointed, containers
  recreated, and the old automount units merely disabled so the nightly power-off retires them.
  Removal of the superseded share definitions is pending until those mounts have cleared.
- **`smb.conf` itself.** The four workstation shares carry `create mask = 0640` and
  `directory mask = 2750` so that new content is born compliant, but the role verifies the result
  on disk rather than the configuration that produced it. That separation is deliberate: masks
  govern one of three ways an object comes into being, and a check that trusted them would be
  blind to the other two.

---

## Related

- [Samba architecture](samba.md) - the share model and what Samba enforces
- [Storage design](storage-design.md) - MergerFS, SnapRAID, the pool layout
- [VM102 node documentation](../nodes/vm102.md)
- [Known errors](known-errors.md) - KE-13 and KE-19 for the same failure class in other layers
