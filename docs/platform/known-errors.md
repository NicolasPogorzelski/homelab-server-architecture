# Known Errors & Workarounds

This document records errors that have been observed in production, their root cause, and the applied fix or workaround.

Unlike the incident response playbooks in [operations.md](./operations.md), these are specific, previously encountered issues — not hypothetical failure scenarios.

---

## KE-1: SQLite on CIFS — "database is locked"

**Affected service:** OpenWebUI (CT230)

**Symptom:**
`peewee.OperationalError: database is locked`

**Root cause:**
SQLite relies on POSIX file locking semantics that are not reliably supported on CIFS/SMB network filesystems. When OpenWebUI's default SQLite database was stored on a CIFS mount, concurrent access caused persistent locking failures.

**Fix:**
SQLite was replaced with PostgreSQL running on local block storage in a dedicated platform container (CT260). This is now an architectural rule: no database files (SQLite or PostgreSQL data directories) may reside on CIFS/SMB or automount-backed network shares.

**Status:** Resolved (architectural decision)

**References:**
- [OpenWebUI service documentation](../services/openwebui.md)
- [PostgreSQL platform service](../services/postgresql-platform.md)

---

## KE-2: Grafana datasource unreachable after host networking switch

**Affected service:** Grafana (LXC200)

**Symptom:**
Grafana dashboards failed silently. The provisioned Prometheus datasource returned connection errors.

**Root cause:**
The monitoring stack was switched to `network_mode: host` in Docker. In bridge mode, Docker provides internal DNS resolution between containers (e.g. `http://prometheus:9090`). With host networking, containers share the host network stack directly — Docker does not create a virtual network and provides no DNS. The datasource URL `http://prometheus:9090` became unresolvable.

**Fix:**
Changed the datasource URL from `http://prometheus:9090` to `http://127.0.0.1:9090`. This applies to all inter-service references in host-networked Docker stacks: configuration files, environment variables, and provisioning templates must use `127.0.0.1` or the host's Tailscale IP, never container names.

**Status:** Resolved

**References:**
- [Design Decision #10](../decisions/design-decisions.md)

---

## KE-3: Failed run-rpc_pipefs.mount in LXC210

**Affected service:** Nextcloud (LXC210)

**Symptom:**
`systemctl --failed` shows `run-rpc_pipefs.mount` as failed.

**Root cause:**
This systemd mount unit is related to NFS/RPC services. It is automatically generated but not required for the Nextcloud stack (which uses CIFS, not NFS). The unit fails because the unprivileged LXC does not have the necessary kernel capabilities for RPC pipe filesystem mounting.

**Fix:**
No fix applied. This is a non-blocking cosmetic failure. Nextcloud operates normally without it.

**Status:** Known, non-blocking

**References:**
- [Nextcloud service documentation](../services/nextcloud.md)

---

## KE-4: Docker creates directories for missing bind-mount files

**Affected services:** Any Docker service with bind-mounted config files (observed: Prometheus on LXC200)

**Symptom:** Container fails to start. Error message: `error mounting "..." to rootfs: not a directory`. Exit code may be misleading (e.g. 127).

**Root cause:** When a Docker bind-mount references a host path that does not exist, Docker does not fail — it silently creates an empty **directory** at that path. If the container expects a file (e.g. a config file), the mount fails with a type mismatch. This is documented Docker behavior, not a bug.

**Common triggers:**
- Config file was never created from `.example` template after initial clone
- Config file was removed by `git clean` (especially with `-x` flag)
- Accidental manual deletion

**Fix:**
1. Remove the empty directory: `rmdir <path>`
2. Recreate the config from the corresponding `.example` template
3. Restart the container

**Scope:** Applies to all gitignored config files mounted as Docker bind-mounts. Currently affected files:
- `docker/monitoring/prometheus/prometheus.yml`
- `docker/monitoring/grafana.env`

**Prevention:** The repo validation script (`scripts/validate-repo.sh`, implemented 2026-04-10) verifies that all expected config files exist and are regular files before container startup.

**Status:** Systematic (Docker design behavior)

**References:**
- [Monitoring platform](./monitoring.md)
- [Design Decision #10](../decisions/design-decisions.md)
