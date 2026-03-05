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

## Storage
- SMB automount trigger: [storage/smb-autofs-trigger.md](storage/smb-autofs-trigger.md)

## Database (planned)
- PostgreSQL backup & restore (planned; pg_dump + restore test + retention)

## AI Stack (planned)
- OpenWebUI health check (planned; mounts + container + DB connectivity)
