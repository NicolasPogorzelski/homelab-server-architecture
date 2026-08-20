# Runbooks

Operational procedures for deterministic recovery and reproducible operations.

**Runbook contract (applies to every runbook):**
- Preconditions (what must be true before starting)
- Commands (copy/paste safe, deterministic order)
- Verification (how to confirm success)
- Failure modes (common errors + what to check next)
- Rollback / abort (required, and enforced by `validate-repo.sh` Check 5)

"Not applicable" is a legitimate rollback section - a procedure that only reads has nothing to
undo - but it has to be written down together with its reason. Omitting the section makes "there is
nothing to reverse" indistinguishable from "nobody considered it", and those two are very different
things to discover at 02:00 with a service down.

Where a step is genuinely irreversible, the section states that plainly and names the **abort
criteria** instead: the conditions under which the step must not be taken at all. `snapraid sync` is
the clearest case in this repository - it has no rollback whatsoever, which is precisely why its
pre-checks are the control.

Related operational model:
- See: [Platform Operations](../docs/platform/operations.md)

---

## Platform
- Hard shutdown recovery: [platform/hard-shutdown-recovery.md](platform/hard-shutdown-recovery.md)
- LVM thin-pool full: [platform/lvm-thin-pool-full.md](platform/lvm-thin-pool-full.md)
- Docker data root migration to aux-disk: [platform/docker-data-root-migration.md](platform/docker-data-root-migration.md)
- Guest backup and restore: [platform/guest-backup-restore.md](platform/guest-backup-restore.md)
- LXC250 rebuild: [platform/lxc250-rebuild.md](platform/lxc250-rebuild.md)
- pveproxy down after boot (Tailscale-IP bind race): [platform/pveproxy-tailscale-boot-race.md](platform/pveproxy-tailscale-boot-race.md)

## Storage
- SMB automount trigger: [storage/smb-autofs-trigger.md](storage/smb-autofs-trigger.md)
- SnapRAID sync: [storage/snapraid-sync.md](storage/snapraid-sync.md)
- SnapRAID scrub: [storage/snapraid-scrub.md](storage/snapraid-scrub.md)
- aux-disk failure rescue (read-only): [storage/aux-disk-failure-rescue.md](storage/aux-disk-failure-rescue.md)

## Database
- PostgreSQL backup: [database/pg-backup.md](database/pg-backup.md)
- PostgreSQL restore: [database/pg-restore.md](database/pg-restore.md)
- Nextcloud MariaDB backup: [database/mariadb-backup.md](database/mariadb-backup.md)

## Integration
- Nextcloud -> Paperless ingestion: [integration/nextcloud-paperless.md](integration/nextcloud-paperless.md)

## AI Stack
- OpenWebUI health check: [ai-stack/openwebui-health.md](ai-stack/openwebui-health.md)
