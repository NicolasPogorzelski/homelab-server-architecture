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

**Status:**
- **Monitoring gap (RESOLVED 2026-06-08):** `blackbox_exporter` deployed on LXC200 probes 7 service endpoints (HTTP + Tailscale Serve HTTPS) with a `ServiceDown` alert rule. Tailscale ACL Rule 1c grants monitoring access to service ports. See [changelog 2026-06-08](./changelog.md) and [Monitoring platform](./monitoring.md).
- **Root cause (OPEN):** Media hang root cause not definitively determined.
- **journald persistence (OPEN):** Logs for the incident window were lost. `Storage=` / `SystemMaxUse=` fix not yet applied on VM100.

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

**Note (separate fault — resolved 2026-06-09):** Paperless did not fully recover after the DB fix — it crash-looped (`RestartCount` 2443) on `Error 111 connecting to localhost:6379` (Redis). **Root cause:** the `paperless-env` role's `defaults/main.yml` shipped `paperless_redis: redis://localhost:6379`. On a Compose **bridge** network `localhost` resolves to paperless' *own* container (no Redis there) — Redis is reachable by its **service name** (`redis://redis:6379`, the same service-name-DNS pattern the compose already uses for `gotenberg`/`tika`). The wrong default was written into `.env` when the role was first applied (2026-05-23) and went unnoticed until blackbox (2026-06-08) — again the KE-8 lesson. **Fix:** corrected the role default to `redis://redis:6379` and redeployed; container now `healthy`, `RestartCount` reset to 0, backend returns HTTP 302 (login redirect, i.e. alive).

**Status:** Resolved. Boot-ordering race fixed + reboot-verified (2026-06-09, `postgresql-boot-order` role); paperless Redis config regression fixed + verified (2026-06-09, `paperless-env` role default).

**References:**
- [LXC260 PostgreSQL node](../nodes/lxc260.md)
- [Tailscale ACL — Rule 1c](./tailscale-acl.md)
- [Monitoring platform](./monitoring.md)

---

## KE-10: Jellyfin loses CUDA access intermittently — container restart required

**Affected service:** Jellyfin (VM100)

**Symptom:**
Hardware transcoding stops working intermittently. Jellyfin becomes effectively unusable —
video playback stalls or fails for all clients. The service appears running but cannot serve
media. A container restart restores GPU access and full functionality.

**Root cause:**
Not fully determined. `pid: "host"` is required for initial NVIDIA Container Toolkit access
and is set in the Compose config (`docker/jellyfin/docker-compose.yml`). The intermittent
loss of CUDA access at runtime suggests the NVML connection to the host driver becomes stale —
exact trigger unknown.

**Workaround:**
```bash
docker restart jellyfin
```

Restores hardware transcoding immediately.

**Automated workaround:** A watchdog script polls `nvidia-smi` inside the container every
30 minutes and restarts Jellyfin automatically on CUDA loss. See deployment instructions
in [Jellyfin service doc](../services/jellyfin.md#cuda-watchdog) and script at
[`snippets/scripts/jellyfin-cuda-watchdog.sh`](../../snippets/scripts/jellyfin-cuda-watchdog.sh).

**Status:** Known, unresolved — automated restart workaround deployed

**References:**
- [VM100 node doc](../nodes/vm100.md)
- [Jellyfin service doc](../services/jellyfin.md)
- [`docker/jellyfin/docker-compose.yml`](../../docker/jellyfin/docker-compose.yml)

---

## KE-11: Grafana admin password not updated by environment variable after first start

**Affected service:** Grafana (LXC200)

**Symptom:**
After changing `GF_SECURITY_ADMIN_PASSWORD` in the `.env` file and restarting the container,
login with the new password fails. The old password remains active.

**Root cause:**
Grafana writes the admin password to its internal database (`grafana.db`) on first container
start. On subsequent starts, the environment variable is ignored — the persisted value in the
database takes precedence. This is documented Grafana behavior, not a bug.

**Fix:**
```bash
docker exec -it grafana grafana-cli admin reset-admin-password <new-password>
```

**Status:** Known, non-blocking

**References:**
- [LXC200 node doc](../nodes/lxc200.md)
- [Monitoring platform](./monitoring.md)

---

## KE-12: pveproxy fails to start after boot (Tailscale-IP bind race)

**Affected component:** Proxmox host — `pveproxy` (web UI / API proxy on `:8006`)

**Symptom:**
After a host reboot, SSH works but the Proxmox web UI on `:8006` is unreachable.
`systemctl is-active pveproxy` is `failed` and nothing listens on `:8006`. The
journal shows, five times within a few seconds of boot:

```
start failed - unable to create socket - Cannot assign requested address
pveproxy.service: Start request repeated too quickly.
```

**Root cause:**
`pveproxy` binds only the host Tailscale IP (`/etc/default/pveproxy` →
`LISTEN_IP=<tailscale-ip-proxmox-host>`, intentional "UI on the tailnet only"
hardening). On boot it starts before `tailscaled` has assigned that IP, so the
bind fails with `EADDRNOTAVAIL`. Unlike PostgreSQL (KE-9) it does not fall back to
a partial bind — it exits non-zero, and after five fast retries systemd stops
trying. The service stays dead until a manual restart. Same fault class as
[KE-9](#ke-9-postgresql-binds-only-loopback-after-boot-tailscale-ip-startup-race).

**Fix:**
Immediate — `systemctl reset-failed pveproxy && systemctl restart pveproxy` (the
`reset-failed` clears the start-limit counter; the restart binds because the IP is
present now). Durable — systemd drop-in
`/etc/systemd/system/pveproxy.service.d/wait-tailscale.conf` ordering after
`tailscaled` plus an `ExecStartPre` that polls until the Tailscale IP is on
`tailscale0` (≤30 s). Validated by warm restart (HTTP 200); cold-boot test pending.

**Status:** Fixed (drop-in installed); cold-boot verification pending

**References:**
- [ADR — pveproxy Tailscale boot ordering](../decisions/pveproxy-tailscale-boot-ordering.md)
- [Runbook — pveproxy boot-race recovery](../../runbooks/platform/pveproxy-tailscale-boot-race.md)
- [Proxmox Host](./proxmox-host.md)

---

## KE-13: Aux1TB physical disk failure (medium errors)

**Affected component:** Proxmox host — Aux1TB auxiliary disk (`/mnt/aux1TB`)

**Symptom:**
Aux1TB will not mount on boot; five LXCs (LXC200/211/220/230/260) fail to start
because their Docker data-root bind-mount sources under `/mnt/aux1TB` are missing.
Earlier, the same mount failure dropped the host into emergency mode (the original
lockout).

**Root cause:**
Unrecoverable hardware medium errors on the disk (a consumer-grade 1 TB drive,
~6.5 years power-on) — not a filesystem-only or cabling fault. Verified in the
kernel log (`critical medium error ... Unrecovered read error`) and SMART
(`Current_Pending_Sector` = `Offline_Uncorrectable` = 7688, `Reported_Uncorrect`
= 18). A read-only mount (`mount -o ro,noload`, no journal replay) still succeeded,
so the live data was recoverable.

**Fix / mitigation:**
`nofail` on the Aux1TB fstab entry keeps the boot out of emergency mode (already in
place). All live data was rescued read-only **before** any repair attempt —
per-directory `tar --numeric-owner --ignore-failed-read` streamed to the admin
notebook, 12 archives (~77 G), all integrity-verified, 0 real read errors. Disk to
be decommissioned; affected services not yet restored (pending data relocation
onto healthy storage). This invalidates the `docker-data-root-migration` runbook
and CLAUDE.md "Adding a New Service" step 6, which both target `/mnt/aux1TB`.

**Status:** Diagnosed; data rescued; disk pending decommission; services pending relocation

**References:**
- [Incident write-up — Aux1TB failure and recovery](./incidents/2026-06-25-aux1tb-failure-and-recovery.md)
- [Runbook — Aux1TB failure rescue](../../runbooks/storage/aux1tb-failure-rescue.md)
- [VM100 node doc](../nodes/vm100.md)
