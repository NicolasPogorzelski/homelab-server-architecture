# Runbooks

Operational procedures for deterministic recovery and reproducible operations.

**Runbook contract (applies to every runbook):**
- Preconditions (what must be true before starting)
- Commands (copy/paste safe, deterministic order)
- Verification (how to confirm success)
- Failure modes (common errors + what to check next)
- Rollback / abort (only if applicable)

Related operational model:
- See: [Platform Operations](../docs/platform/operations.md)

---

## Platform
- Hard shutdown recovery: [platform/hard-shutdown-recovery.md](platform/hard-shutdown-recovery.md)
- LVM thin-pool full: [platform/lvm-thin-pool-full.md](platform/lvm-thin-pool-full.md)

## Storage
- SMB automount trigger: [storage/smb-autofs-trigger.md](storage/smb-autofs-trigger.md)
- SnapRAID sync: [storage/snapraid-sync.md](storage/snapraid-sync.md)
- SnapRAID scrub: [storage/snapraid-scrub.md](storage/snapraid-scrub.md)

## Database
- PostgreSQL backup: [database/pg-backup.md](database/pg-backup.md)
- PostgreSQL restore: [database/pg-restore.md](database/pg-restore.md)

## Integration
- Nextcloud → Paperless ingestion: [integration/nextcloud-paperless.md](integration/nextcloud-paperless.md)

## AI Stack
- OpenWebUI health check: [ai-stack/openwebui-health.md](ai-stack/openwebui-health.md)

## Platform
- Docker data root migration to Aux1TB: [platform/docker-data-root-migration.md](platform/docker-data-root-migration.md)
- LXC250 rebuild: [platform/lxc250-rebuild.md](platform/lxc250-rebuild.md)
