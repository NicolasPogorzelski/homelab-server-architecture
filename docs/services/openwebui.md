# OpenWebUI (CT230) — Service Documentation

## Goal
- OpenWebUI as central UI for the AI stack
- Tailscale-only access
- Two inference nodes (Gaming PC + VM100)
- Persistent memory / vector store
- Professional storage separation (no “quick & dirty”)
- No SQLite or PostgreSQL on CIFS/SMB

## Incident: SQLite on CIFS/SMB
**Symptom:** `peewee.OperationalError: database is locked`  
**Root cause:** SQLite locking semantics are not reliable on CIFS/SMB.  
**Rule:** No database (SQLite/PostgreSQL) on CIFS/SMB or automount-backed network shares.

## Storage Strategy
| Data type | Critical | Location |
|---|---:|---|
| DB (PostgreSQL) | Yes | Local block FS (ext4/xfs/zfs) |
| App state / config | Medium | Local (Aux1TB) |
| Logs | Low | Local (Aux1TB) |
| Uploads | Yes | MergerFS/SMB |
| Vector store | Yes | MergerFS/SMB |
| DB backups | Yes | MergerFS/SMB |

## Paths (Truth Sources)
### Proxmox Host
- SMB mount (autofs): `/mnt/smb/openwebui`
- Local block storage: `/mnt/aux1TB/openwebui`

### CT230 (ai-openwebui)
- SMB via bind mount: `mp0: /mnt/smb/openwebui -> /data/openwebui`
- Local via bind mount (planned): `mp1: /mnt/aux1TB/openwebui -> /var/lib/openwebui`

## Planned Volume Layout (CT230)
- App data: `/var/lib/openwebui/appdata` (Aux1TB)
- Logs: `/var/lib/openwebui/logs` (Aux1TB)
- Uploads: `/data/openwebui/uploads` (SMB)
- Vector: `/data/openwebui/vector` (SMB)
- Backups: `/data/openwebui/backups` (SMB)

## Dependency Notes
- OpenWebUI must not store DB files on SMB.
- PostgreSQL will run as a centralized platform service (separate LXC, Tailscale-only).
- SMB automount should be stabilized on host boot: see `runbooks/storage/smb-autofs-trigger.md`.

## Database Dependency

OpenWebUI relies on a centralized PostgreSQL platform service
running in a dedicated infrastructure LXC (250).

The database is accessed exclusively via the Tailnet.

See:
docs/services/postgresql-platform.md
