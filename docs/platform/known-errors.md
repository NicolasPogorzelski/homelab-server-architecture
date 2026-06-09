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

**Prevention:** No automated prevention. The repo validation script (`scripts/validate-repo.sh`) is a repo structural validator — it checks for `.env.example` files, doc section requirements, sanitization, and committed secrets. It does not check whether runtime config files derived from `.example` templates have been created. After cloning, manually copy each `.example` file to the required config path before starting containers.

**Status:** Systematic (Docker design behavior)

**References:**
- [Monitoring platform](./monitoring.md)
- [Design Decision #10](../decisions/design-decisions.md)

---

## KE-5: Vaultwarden SQLite on CIFS — acknowledged technical debt

**Affected service:** Vaultwarden (LXC240)

**Symptom:**
Vaultwarden's SQLite database (`db.sqlite3`) resides on the CIFS mount at `/opt/vaultwarden`
(mp0 on LXC240). This violates the architectural rule established by KE-1: no database files
on CIFS/SMB-backed mounts.

**Root cause:**
Vaultwarden was deployed with its default SQLite backend before the KE-1 resolution codified
the "no database files on CIFS" rule. The `/opt/vaultwarden` bind-mount was configured as the
service data directory without isolating the database to local storage.

**Fix:**
Not yet applied. Migration to PostgreSQL (CT260) is planned. Until migration, the risk is
accepted: Vaultwarden is a single-user deployment with low write frequency, reducing the
probability of POSIX locking failures relative to the multi-user OpenWebUI case (KE-1).

**Status:** Known, unresolved (planned migration to CT260)

**References:**
- [KE-1: SQLite on CIFS — "database is locked"](#ke-1-sqlite-on-cifs--database-is-locked)
- [Vaultwarden service documentation](../services/vaultwarden.md)
- [PostgreSQL platform service](../services/postgresql-platform.md)

---

## KE-6: Tailscale userspace-networking prevents node_exporter from binding to Tailscale IP

**Affected service:** node_exporter (LXC240 Vaultwarden)

**Symptom:**
`listen tcp <tailscale-ip-lxc240>:9100: bind: cannot assign requested address`
node_exporter fails to start. `tailscale status` shows the node as reachable,
but `ip addr show tailscale0` reports the device does not exist.

**Root cause:**
`/etc/default/tailscaled` contained `FLAGS="--tun=userspace-networking"`.
In userspace-networking mode, Tailscale does not create a kernel `tailscale0`
interface. The Tailscale IP is not assigned to any OS-level interface,
so `bind()` calls targeting that IP fail with EADDRNOTAVAIL.
This was a legacy workaround predating the CT210-pattern TUN configuration.

**Fix:**
Remove the flag from `/etc/default/tailscaled`. Restart tailscaled. Verify `tailscale0` appears
with the correct IP via `ip addr show tailscale0`. Then restart node_exporter.

**Status:** Resolved (LXC240)

---

## KE-7: Package corruption when LVM thin-pool overflows during apt upgrade

**Affected:** All nodes (platform-wide)

**Observed instances:**
- 2026-04-25: LXC230 (`tailscaled`), LXC260 (`bash`, `tailscaled`) — discovered during incident
- 2026-04-26: LXC220 (`dockerd`, `runc`, `ctr`) — discovered post-incident via service outage

**Symptom:**
- `No space left on device` during `apt dist-upgrade` despite `df -h /` reporting free space
- `dpkg-deb: error: not a Debian format archive` on cached `.deb` files
- `file /usr/sbin/tailscaled` returns `data` instead of `ELF 64-bit executable`
- `file /bin/bash` returns `data` — bash non-functional, SSH sessions return `Exec format error`
- `file /usr/bin/dockerd` returns `data` — Docker daemon fails with `status=203/EXEC` (systemd cannot exec binary)
- `file /usr/bin/runc` returns `data` — containers fail to start: `exec format error`
- Ansible: `Failed to create temporary directory` on affected nodes
- VM enters `status: io-error` state (QEMU suspends on write failure)
- After reinstalling corrupt Docker packages: `docker start` fails with `container with given ID already exists` — stale containerd task state left over from ungraceful daemon shutdown

**Root cause:**
The `local-lvm` thin-pool on the Proxmox host reached 100% utilization during a parallel
`apt dist-upgrade` across all nodes. When the pool is full, disk writes fail silently at the
block level — packages are partially downloaded, dpkg writes are truncated mid-binary,
and the filesystem still reports virtual free space because thin-pool utilization is not
visible from inside the container.

No periodic `fstrim` was running, so deleted blocks were never returned to the pool.

Corruption may not surface immediately — binaries already loaded into memory continue running
until the next restart. Services that were upgraded but not restarted during the incident
(e.g. `dockerd` on LXC220) only fail when systemd attempts to exec the corrupt binary on
the next start.

**Fix:**
1. Clear apt cache on all nodes: `apt-get clean`
2. Run fstrim via `nsenter` from Proxmox host for all LXCs (fstrim blocked inside containers)
3. Resume frozen VMs: `qm resume <vmid>`
4. Repair dpkg state: `dpkg --configure -a`, `apt --fix-broken install -y`
5. Find all corrupt non-conffile packages: `dpkg --verify 2>&1 | grep -v ' c /'`
6. Reinstall all corrupt packages in one pass: `apt-get install --reinstall <pkg1> <pkg2> ...`
7. Restart affected services: `systemctl restart <service>`
8. If Docker containers fail to start after Docker reinstall — clear stale containerd state:
   ```
   docker rm -f <container>
   cd <compose-dir> && docker compose up -d
   ```
9. Re-run upgrade with `serial: 1` to prevent pool spike

**Detection after the fact:**
`dpkg --verify` compares every installed file against its dpkg-recorded checksum.
Output lines without a `c` flag are non-conffile mismatches — these are corrupt binaries.
Lines with `c` are admin-modified conffiles and are expected.

```bash
# Show only corrupt non-conffiles (ignore expected conffile modifications):
dpkg --verify 2>&1 | grep -v ' c /'
```

**Status:** Resolved (2026-04-25 initial incident; LXC220 recovered 2026-04-26)

**References:**
- [Runbook: LVM thin-pool full](../../runbooks/platform/lvm-thin-pool-full.md)
- [lxc-fstrim.sh](../../snippets/scripts/lxc-fstrim.sh)

---

## KE-8: Media services hang while the node stays healthy (observability blind spot)

**Affected services:** Jellyfin + Audiobookshelf (VM100)

**Observed instance:**
- 2026-06-06 (~12:00–14:36 UTC): both services unreachable; recovered only after a VM100 restart. Nextcloud (LXC210) and other nodes stayed reachable.

**Symptom:**
- From the client side, no connection to Jellyfin or Audiobookshelf could be established — both web UIs were simply unreachable.
- Server-side the picture was a hang, not a crash: Jellyfin logged only sporadic `WS request → closed` with no error; Audiobookshelf went silent after `Listening on port :80`. The processes were alive but not serving.
- A VM100 restart restored both immediately.

**What was proven and excluded:**
- **Not** the storage pool being full: VM102 ran continuously through the window (`wtmp`); MergerFS was ~96% but never 0 bytes (no `ENOSPC`).
- **Not** VM102 down, **not** network/Tailscale loss: Prometheus `up{job="node-vm100-gpu"}` was `1` for 300/300 samples in the window (one 60s gap = the restart only).
- **Not** a hard CIFS hang: no `CIFS VFS: server not responding` / hung-task messages in `/var/log/kern.log`.
- **Not** GPU/kernel break: GPU transcoding worked immediately after the restart (the morning's `unattended-upgrade` kernel bump to `5.15.0-181` was unrelated).
- **Not** resource exhaustion: `node_procs_blocked` max = 1, `node_load5` max = 0.27, ≥14 GiB RAM free throughout.

**Root cause:** Not definitively determined. Leading (unproven) hypothesis: an application-level degradation of the shared media backend (slow/stalled SMB to VM102 — an interruptible wait, therefore invisible in `procs_blocked`/load) or an internal container deadlock. Unprovable after the fact because the application/kernel logs for the window were lost (see gaps below).

**Recovery:** Restart VM100, or less invasively restart the affected containers (`docker restart jellyfin audiobookshelf` on VM100). This re-establishes the automount/SMB sessions and clears any wedged container state.

**Contributing observability gaps (the real lesson):**
1. **No service-level monitoring.** Alerts cover `NodeDown` (node_exporter:9100) and disk only. node_exporter answered the whole time while ports 8096/13378 were dead — no alert fired. A healthy node can have dead services.
2. **journald not persisting logs.** Despite `/var/log/journal`, the June logs were gone (`journalctl --list-boots` jumped from May 28 to the current boot); forensics relied on `wtmp`, `apt`/`dpkg` text logs, Docker JSON logs, and Prometheus instead.

**Status:** Recovery known; root cause unconfirmed; remediation tracked (service-level probes, journald persistence) — see CLAUDE.md "Known Technical Debt & Gotchas". Service-level probing was implemented 2026-06-08 (blackbox_exporter); journald persistence still open.

**References:**
- [VM100 node documentation](../nodes/vm100.md)
- [Monitoring platform](./monitoring.md)

---

## KE-9: PostgreSQL binds only loopback after boot (Tailscale-IP startup race)

**Affected services:** OpenWebUI (LXC230), Paperless-ngx (LXC211) — i.e. all consumers of the central PostgreSQL on LXC260. Services not using LXC260 (Jellyfin, Audiobookshelf, Calibre-Web, Nextcloud=local MariaDB, Vaultwarden=SQLite) were unaffected.

**Observed instance:**
- 2026-06-08: discovered by the newly deployed `blackbox_exporter` on its very first run — `probe_success=0` for paperless + openwebui (both 502 from `tailscale serve`).

**Symptom:**
- `tailscale serve` on :443 answered but returned **HTTP 502** (dead backend).
- OpenWebUI crash-looped with `UnboundLocalError: cannot access local variable 'db'` in `handle_peewee_migration` (its own buggy handling of a failed DB connect).
- Paperless app did not answer on `127.0.0.1:8000` (later found to have a *separate* Redis fault — see note).

**Root cause:** The native PostgreSQL on LXC260 (re)started at boot (~07:08) **before the Tailscale interface had its IP** (`100.x`). `listen_addresses` is correctly set to `127.0.0.1, <tailscale-ip>`, but PostgreSQL can only bind addresses that exist at startup → it bound loopback only and never re-bound the Tailscale IP. Remote DB clients over Tailscale → connection refused/timeout → services fail.

**Why monitoring missed it (until blackbox):** `pg_up=1` was green because `postgres_exporter` runs locally on LXC260 and connects via loopback — it cannot see that the *remote* (Tailscale) bind is missing. Node-level `up` was also green. Only the service-level blackbox probe exposed it. This is the KE-8 lesson, validated.

**Verification commands:**
```bash
ss -ltn | grep ':5432'                                # which addresses is postgres actually bound to?
sudo -u postgres psql -tAc 'SHOW listen_addresses;'   # what it is *supposed* to bind
```
A mismatch (config lists the Tailscale IP, `ss` shows only `127.0.0.1`) is the signature.

**Recovery:** Restart PostgreSQL once the Tailscale IP is up — `systemctl restart postgresql` on LXC260 → it then binds `<tailscale-ip>:5432`. OpenWebUI recovered automatically via its restart policy.

**Durable fix (applied 2026-06-09):** Ansible role `postgresql-boot-order` deploys a systemd drop-in on `postgresql@15-main.service` (`After=`/`Wants=tailscaled.service`) plus an `ExecStartPre=/usr/local/bin/wait-for-tailscale-ip.sh` that blocks until this node's Tailscale IPv4 is actually present in `ip addr` before PostgreSQL starts. `listen_addresses='*'` was **rejected** — it binds `0.0.0.0` incl. the LAN interface, violating the platform binding rule. Rationale and rejected alternatives: [ADR — PostgreSQL Boot Ordering](../decisions/postgresql-tailscale-boot-ordering.md). Verified by a fresh reboot of LXC260: the gate reported `tailscale IP present after 2s` and PostgreSQL bound `<tailscale-ip>:5432` with no bind error (vs. `Cannot assign requested address` on the prior two boots).

**Note (separate fault):** Paperless did not fully recover after the DB fix — it crash-loops on `Error 111 connecting to localhost:6379` (Redis); its `init-wait-for-redis` step fails and the container exits. Independent container-network/config issue (`PAPERLESS_REDIS` vs. `network_mode`), tracked separately.

**Status:** Resolved for the boot-ordering race (durable fix applied + reboot-verified 2026-06-09). Paperless Redis issue still open (separate fault).

**References:**
- [LXC260 PostgreSQL node](../nodes/lxc260.md)
- [Tailscale ACL — Rule 1c](./tailscale-acl.md)
- [Monitoring platform](./monitoring.md)
