# Known Errors & Workarounds

This document records errors that have been observed in production, their root cause, and the applied fix or workaround.

Unlike the incident response playbooks in [operations.md](./operations.md), these are specific, previously encountered issues - not hypothetical failure scenarios.

Every entry carries an explicit `<a id="ke-N"></a>` anchor above its heading, so other documents
can link to `known-errors.md#ke-N` without depending on the heading text. Four such links were
already broken on 2026-07-10 because the auto-generated anchor is the full slugified title, and
titles get reworded. Keep the anchor when adding an entry; `validate-repo.sh` Check 2 verifies the
file path, not the fragment.

---

<a id="ke-1"></a>

## KE-1: SQLite on CIFS - "database is locked"

**Affected service:** OpenWebUI (CT230)

**Symptom:**
`peewee.OperationalError: database is locked`

**Root cause:**
SQLite relies on POSIX file locking semantics that are not reliably supported on CIFS/SMB network filesystems. When OpenWebUI's default SQLite database was stored on a CIFS mount, concurrent access caused persistent locking failures.

**Fix:**
SQLite was replaced with PostgreSQL running on local block storage in a dedicated platform container (lxc260). This is now an architectural rule: no database files (SQLite or PostgreSQL data directories) may reside on CIFS/SMB or automount-backed network shares.

**Status:** Resolved (architectural decision)

**References:**
- [OpenWebUI service documentation](../services/openwebui.md)
- [PostgreSQL platform service](../services/postgresql-platform.md)

---

<a id="ke-2"></a>

## KE-2: Grafana datasource unreachable after host networking switch

**Affected service:** Grafana (LXC200)

**Symptom:**
Grafana dashboards failed silently. The provisioned Prometheus datasource returned connection errors.

**Root cause:**
The monitoring stack was switched to `network_mode: host` in Docker. In bridge mode, Docker provides internal DNS resolution between containers (e.g. `http://prometheus:9090`). With host networking, containers share the host network stack directly - Docker does not create a virtual network and provides no DNS. The datasource URL `http://prometheus:9090` became unresolvable.

**Fix:**
Changed the datasource URL from `http://prometheus:9090` to `http://127.0.0.1:9090`. This applies to all inter-service references in host-networked Docker stacks: configuration files, environment variables, and provisioning templates must use `127.0.0.1` or the host's Tailscale IP, never container names.

**Status:** Resolved

**References:**
- [Design Decision #10](../decisions/design-decisions.md)

---

<a id="ke-3"></a>

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

<a id="ke-4"></a>

## KE-4: Docker creates directories for missing bind-mount files

**Affected services:** Any Docker service with bind-mounted config files (observed: Prometheus on LXC200)

**Symptom:** Container fails to start. Error message: `error mounting "..." to rootfs: not a directory`. Exit code may be misleading (e.g. 127).

**Root cause:** When a Docker bind-mount references a host path that does not exist, Docker does not fail - it silently creates an empty directory at that path. If the container expects a file (e.g. a config file), the mount fails with a type mismatch. This is documented Docker behavior, not a bug.

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

**Prevention:** No automated prevention. The repo validation script (`scripts/validate-repo.sh`) is a repo structural validator - it checks for `.env.example` files, doc section requirements, sanitization, and committed secrets. It does not check whether runtime config files derived from `.example` templates have been created. After cloning, manually copy each `.example` file to the required config path before starting containers.

**Status:** Systematic (Docker design behavior)

**References:**
- [Monitoring platform](./monitoring.md)
- [Design Decision #10](../decisions/design-decisions.md)

---

<a id="ke-5"></a>

## KE-5: Vaultwarden SQLite on CIFS - acknowledged technical debt

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
Not yet applied. Migration to PostgreSQL (lxc260) is planned. Until migration, the risk is
accepted: Vaultwarden is a single-user deployment with low write frequency, reducing the
probability of POSIX locking failures relative to the multi-user OpenWebUI case (KE-1).

**Status:** Known, unresolved (planned migration to lxc260)

**References:**
- [KE-1: SQLite on CIFS - "database is locked"](#ke-1-sqlite-on-cifs--database-is-locked)
- [Vaultwarden service documentation](../services/vaultwarden.md)
- [PostgreSQL platform service](../services/postgresql-platform.md)

---

<a id="ke-6"></a>

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

### Recurrence on LXC220 (2026-07-28) - same cause, different delivery, misleading symptom

Closing this entry on LXC240 in 2026 fixed the node where the error was noticed. **No fleet sweep
followed**, and LXC220 was running in userspace-networking mode the whole time - its
`node_exporter` had, as far as can be established, never been scraped successfully.

Two things made it hard to see:

**It was not a flag in a config file.** `/etc/default/tailscaled` on LXC220 read `FLAGS=""`, and
the packaged unit is unmodified. The mode came from a second, hand-written systemd unit,
`/etc/systemd/system/tailscaled-userspace.service`, `enabled` alongside the stock
`tailscaled.service`. Every boot started *two* daemons against the same `--state` and `--socket`
paths, 2 s apart. Grepping configuration files finds nothing; only the running process shows it:

```
ps -o pid,ppid,lstart,args -C tailscaled     # expect exactly one process
systemctl list-unit-files | grep -i tailscale # expect exactly one enabled unit
systemctl status <pid>                        # maps a stray process back to its unit
```

**The symptom is the inverse of the one described above.** On LXC240 the bind *failed* and the
service would not start. On LXC220 `node_exporter` was `active`, `ss -tlnp` showed it listening on
the Tailscale IP, and `ip addr show tailscale0` showed the interface with its address - everything
an operator would check looked correct. Only the scrape failed, with `connection refused`, because
the userspace daemon terminates the connection in netstack and never hands it to the kernel socket
that `node_exporter` is bound to. `tailscale serve` traffic (port 443, Calibre-Web) worked
throughout, since serve is answered inside that same process - which is why the node looked healthy
in the blackbox probes while its metrics target was down.

**Do not conclude from a successful `bind()` that this error is absent.** The discriminator is a
scrape from the monitoring node, not the local socket state:

```
pct exec 200 -- curl -s -o /dev/null -w '%{http_code}\n' http://<tailscale-ip-lxc220>:9100/metrics
```

**Fix applied:** `systemctl disable --now tailscaled-userspace.service`, then
`systemctl restart tailscaled.service` so the remaining daemon claims the TUN device cleanly.
Verified: one `tailscaled` process, `tailscale0` carries the address, scrape returns `HTTP 200`,
Prometheus target `health: up`, `NodeDown` cleared, and Calibre-Web still answers `HTTP 302`
through `tailscale serve` with `probe_success = 1`. `/dev/net/tun` was present on the node all
along, so the userspace mode had no remaining purpose.

**Status:** Resolved on LXC240 (2026) and on LXC220 (2026-07-28). **Cold-boot verified
2026-08-13:** exactly one `tailscaled` process on lxc220 after a real host power cycle, no failed
unit, node scraped. The unit file is disabled, not deleted (confirmed still present 2026-08-13),
so a future `systemctl enable` would revive it - remove it during the next lxc220 pass.
**Lesson: a per-node fix is not a fleet fix.** When closing a configuration error, sweep the other
nodes for the same condition and record that you did.

**References:**
- [KE-18 - Tailscale readiness races](#ke-18-services-start-before-tailscale-is-ready-ordering-is-not-readiness) (different cause, same `EADDRNOTAVAIL` symptom - check which one you have)

---

<a id="ke-7"></a>

## KE-7: Package corruption when LVM thin-pool overflows during apt upgrade

**Affected:** All nodes (platform-wide)

**Observed instances:**
- 2026-04-25: LXC230 (`tailscaled`), LXC260 (`bash`, `tailscaled`) - discovered during incident
- 2026-04-26: LXC220 (`dockerd`, `runc`, `ctr`) - discovered post-incident via service outage

**Symptom:**
- `No space left on device` during `apt dist-upgrade` despite `df -h /` reporting free space
- `dpkg-deb: error: not a Debian format archive` on cached `.deb` files
- `file /usr/sbin/tailscaled` returns `data` instead of `ELF 64-bit executable`
- `file /bin/bash` returns `data` - bash non-functional, SSH sessions return `Exec format error`
- `file /usr/bin/dockerd` returns `data` - Docker daemon fails with `status=203/EXEC` (systemd cannot exec binary)
- `file /usr/bin/runc` returns `data` - containers fail to start: `exec format error`
- Ansible: `Failed to create temporary directory` on affected nodes
- VM enters `status: io-error` state (QEMU suspends on write failure)
- After reinstalling corrupt Docker packages: `docker start` fails with `container with given ID already exists` - stale containerd task state left over from ungraceful daemon shutdown

**Root cause:**
The `local-lvm` thin-pool on the Proxmox host reached 100% utilization during a parallel
`apt dist-upgrade` across all nodes. When the pool is full, disk writes fail silently at the
block level - packages are partially downloaded, dpkg writes are truncated mid-binary,
and the filesystem still reports virtual free space because thin-pool utilization is not
visible from inside the container.

No periodic `fstrim` was running, so deleted blocks were never returned to the pool.

Corruption may not surface immediately - binaries already loaded into memory continue running
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
8. If Docker containers fail to start after Docker reinstall - clear stale containerd state:
   ```
   docker rm -f <container>
   cd <compose-dir> && docker compose up -d
   ```
9. Re-run upgrade with `serial: 1` to prevent pool spike

**Detection after the fact:**
`dpkg --verify` compares every installed file against its dpkg-recorded checksum.
Output lines without a `c` flag are non-conffile mismatches - these are corrupt binaries.
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

<a id="ke-8"></a>

## KE-8: Media services hang while the node stays healthy (observability blind spot)

**Affected services:** Jellyfin + Audiobookshelf (VM100)

**Observed instance:**
- 2026-06-06 (~12:00-14:36 UTC): both services unreachable; recovered only after a VM100 restart. Nextcloud (LXC210) and other nodes stayed reachable.

**Symptom:**
- From the client side, no connection to Jellyfin or Audiobookshelf could be established - both web UIs were simply unreachable.
- Server-side the picture was a hang, not a crash: Jellyfin logged only sporadic `WS request -> closed` with no error; Audiobookshelf went silent after `Listening on port :80`. The processes were alive but not serving.
- A VM100 restart restored both immediately.

**What was proven and excluded:**
- **Not** the storage pool being full: VM102 ran continuously through the window (`wtmp`); MergerFS was ~96% but never 0 bytes (no `ENOSPC`).
- **Not** VM102 down, not network/Tailscale loss: Prometheus `up{job="node-vm100-gpu"}` was `1` for 300/300 samples in the window (one 60s gap = the restart only).
- **Not** a hard CIFS hang: no `CIFS VFS: server not responding` / hung-task messages in `/var/log/kern.log`.
- **Not** GPU/kernel break: GPU transcoding worked immediately after the restart (the morning's `unattended-upgrade` kernel bump to `5.15.0-181` was unrelated).
- **Not** resource exhaustion: `node_procs_blocked` max = 1, `node_load5` max = 0.27, >=14 GiB RAM free throughout.

**Root cause:** Not definitively determined. Leading (unproven) hypothesis: an application-level degradation of the shared media backend (slow/stalled SMB to VM102 - an interruptible wait, therefore invisible in `procs_blocked`/load) or an internal container deadlock. Unprovable after the fact because the application/kernel logs for the window were lost (see gaps below).

**Recovery:** Restart VM100, or less invasively restart the affected containers (`docker restart jellyfin audiobookshelf` on VM100). This re-establishes the automount/SMB sessions and clears any wedged container state.

**Contributing observability gaps (the real lesson):**
1. **No service-level monitoring.** Alerts cover `NodeDown` (node_exporter:9100) and disk only. node_exporter answered the whole time while ports 8096/13378 were dead - no alert fired. A healthy node can have dead services.
2. **journald not persisting logs.** Despite `/var/log/journal`, the June logs were gone (`journalctl --list-boots` jumped from May 28 to the current boot); forensics relied on `wtmp`, `apt`/`dpkg` text logs, Docker JSON logs, and Prometheus instead.

**Status:**
- **Monitoring gap (RESOLVED 2026-06-08):** `blackbox_exporter` deployed on LXC200 probes 7 service endpoints (HTTP + Tailscale Serve HTTPS) with a `ServiceDown` alert rule. Tailscale ACL Rule 1c grants monitoring access to service ports. See [changelog 2026-06-08](./changelog.md) and [Monitoring platform](./monitoring.md).
- **Root cause (OPEN):** Media hang root cause not definitively determined.
- **journald persistence (NOT A GAP - corrected 2026-07-10, re-measured 2026-08-13):** the logs for the incident window were indeed lost, but not because the journal is volatile. Both VMs have `/var/log/journal/<machine-id>/` and retain many boots - vm100 111 boots, vm102 29 as of 2026-08-13. `Storage=` is unset, so `auto` applies, which is persistent whenever that directory exists. What remains is hardening, not repair: pin `Storage=persistent` and an explicit `SystemMaxUse=`, so persistence is a property of the configuration rather than of a directory that happens to exist and would degrade to RAM-only if it were ever removed.

**References:**
- [VM100 node documentation](../nodes/vm100.md)
- [Monitoring platform](./monitoring.md)

---

<a id="ke-9"></a>

## KE-9: PostgreSQL binds only loopback after boot (Tailscale-IP startup race)

**Affected services:** OpenWebUI (LXC230), Paperless-ngx (LXC211) - i.e. all consumers of the central PostgreSQL on LXC260. Services not using LXC260 (Jellyfin, Audiobookshelf, Calibre-Web, Nextcloud=local MariaDB, Vaultwarden=SQLite) were unaffected.

**Observed instance:**
- 2026-06-08: discovered by the newly deployed `blackbox_exporter` on its very first run - `probe_success=0` for paperless + openwebui (both 502 from `tailscale serve`).

**Symptom:**
- `tailscale serve` on :443 answered but returned HTTP 502 (dead backend).
- OpenWebUI crash-looped with `UnboundLocalError: cannot access local variable 'db'` in `handle_peewee_migration` (its own buggy handling of a failed DB connect).
- Paperless app did not answer on `127.0.0.1:8000` (later found to have a *separate* Redis fault - see note).

**Root cause:** The native PostgreSQL on LXC260 (re)started at boot (~07:08) before the Tailscale interface had its IP (`100.x`). `listen_addresses` is correctly set to `127.0.0.1, <tailscale-ip>`, but PostgreSQL can only bind addresses that exist at startup -> it bound loopback only and never re-bound the Tailscale IP. Remote DB clients over Tailscale -> connection refused/timeout -> services fail.

**Why monitoring missed it (until blackbox):** `pg_up=1` was green because `postgres_exporter` runs locally on LXC260 and connects via loopback - it cannot see that the *remote* (Tailscale) bind is missing. Node-level `up` was also green. Only the service-level blackbox probe exposed it. This is the KE-8 lesson, validated.

**Verification commands:**
```bash
ss -ltn | grep ':5432'                                # which addresses is postgres actually bound to?
sudo -u postgres psql -tAc 'SHOW listen_addresses;'   # what it is *supposed* to bind
```
A mismatch (config lists the Tailscale IP, `ss` shows only `127.0.0.1`) is the signature.

**Recovery:** Restart PostgreSQL once the Tailscale IP is up - `systemctl restart postgresql` on LXC260 -> it then binds `<tailscale-ip>:5432`. OpenWebUI recovered automatically via its restart policy.

**Durable fix (applied 2026-06-09):** Ansible role `postgresql-boot-order` deploys a systemd drop-in on `postgresql@15-main.service` (`After=`/`Wants=tailscaled.service`) plus an `ExecStartPre=/usr/local/bin/wait-for-tailscale-ip.sh` that blocks until this node's Tailscale IPv4 is actually present in `ip addr` before PostgreSQL starts. `listen_addresses='*'` was rejected - it binds `0.0.0.0` incl. the LAN interface, violating the platform binding rule. Rationale and rejected alternatives: [ADR - PostgreSQL Boot Ordering](../decisions/postgresql-tailscale-boot-ordering.md). Verified by a fresh reboot of LXC260: the gate reported `tailscale IP present after 2s` and PostgreSQL bound `<tailscale-ip>:5432` with no bind error (vs. `Cannot assign requested address` on the prior two boots).

**Note (separate fault - resolved 2026-06-09):** Paperless did not fully recover after the DB fix - it crash-looped (`RestartCount` 2443) on `Error 111 connecting to localhost:6379` (Redis). Root cause: the `paperless-env` role's `defaults/main.yml` shipped `paperless_redis: redis://localhost:6379`. On a Compose bridge network `localhost` resolves to paperless' *own* container (no Redis there) - Redis is reachable by its service name (`redis://redis:6379`, the same service-name-DNS pattern the compose already uses for `gotenberg`/`tika`). The wrong default was written into `.env` when the role was first applied (2026-05-23) and went unnoticed until blackbox (2026-06-08) - again the KE-8 lesson. Fix: corrected the role default to `redis://redis:6379` and redeployed; container now `healthy`, `RestartCount` reset to 0, backend returns HTTP 302 (login redirect, i.e. alive).

**Status:** Resolved. Boot-ordering race fixed + reboot-verified (2026-06-09, `postgresql-boot-order` role); paperless Redis config regression fixed + verified (2026-06-09, `paperless-env` role default).

**References:**
- [LXC260 PostgreSQL node](../nodes/lxc260.md)
- [Tailscale ACL - Rule 1c](./tailscale-acl.md)
- [Monitoring platform](./monitoring.md)

---

<a id="ke-10"></a>

## KE-10: Jellyfin loses CUDA access intermittently - container restart required

**Affected service:** Jellyfin (VM100)

**Symptom:**
Hardware transcoding stops working intermittently. Jellyfin becomes effectively unusable -
video playback stalls or fails for all clients. The service appears running but cannot serve
media. A container restart restores GPU access and full functionality.

**Root cause:**
Not fully determined. `pid: "host"` is required for initial NVIDIA Container Toolkit access
and is set in the Compose config (`docker/jellyfin/docker-compose.yml`). The intermittent
loss of CUDA access at runtime suggests the NVML connection to the host driver becomes stale -
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

**Status:** Known, unresolved - automated restart workaround deployed. **The fault is active, not
historical: the watchdog last restarted Jellyfin on 2026-08-07 06:10 and 2026-08-10 10:44**
(journal of `jellyfin-cuda-watchdog.service` on vm100, read 2026-08-13). Every occurrence is
absorbed silently by the workaround, so the only record that the root cause is still live is that
journal - no alert fires, because from the outside the service recovers.

**References:**
- [VM100 node doc](../nodes/vm100.md)
- [Jellyfin service doc](../services/jellyfin.md)
- [`docker/jellyfin/docker-compose.yml`](../../docker/jellyfin/docker-compose.yml)

---

<a id="ke-11"></a>

## KE-11: Grafana admin password not updated by environment variable after first start

**Affected service:** Grafana (LXC200)

**Symptom:**
After changing `GF_SECURITY_ADMIN_PASSWORD` in the `.env` file and restarting the container,
login with the new password fails. The old password remains active.

**Root cause:**
Grafana writes the admin password to its internal database (`grafana.db`) on first container
start. On subsequent starts, the environment variable is ignored - the persisted value in the
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

<a id="ke-12"></a>

## KE-12: pveproxy fails to start after boot (Tailscale-IP bind race)

**Affected component:** Proxmox host - `pveproxy` (web UI / API proxy on `:8006`)

**Symptom:**
After a host reboot, SSH works but the Proxmox web UI on `:8006` is unreachable.
`systemctl is-active pveproxy` is `failed` and nothing listens on `:8006`. The
journal shows, five times within a few seconds of boot:

```
start failed - unable to create socket - Cannot assign requested address
pveproxy.service: Start request repeated too quickly.
```

**Root cause:**
`pveproxy` binds only the host Tailscale IP (`/etc/default/pveproxy` ->
`LISTEN_IP=<tailscale-ip-proxmox-host>`, intentional "UI on the tailnet only"
hardening). On boot it starts before `tailscaled` has assigned that IP, so the
bind fails with `EADDRNOTAVAIL`. Unlike PostgreSQL (KE-9) it does not fall back to
a partial bind - it exits non-zero, and after five fast retries systemd stops
trying. The service stays dead until a manual restart. Same fault class as
[KE-9](#ke-9-postgresql-binds-only-loopback-after-boot-tailscale-ip-startup-race).

**Fix:**
Immediate - `systemctl reset-failed pveproxy && systemctl restart pveproxy` (the
`reset-failed` clears the start-limit counter; the restart binds because the IP is
present now). Durable - systemd drop-in
`/etc/systemd/system/pveproxy.service.d/wait-tailscale.conf` ordering after
`tailscaled` plus an `ExecStartPre` that polls until the Tailscale IP is on
`tailscale0` (<=30 s). Validated by warm restart (HTTP 200) at the time.

**Cold-boot verified 2026-08-13.** On a real host power cycle (boot at 10:52:21) the unit started
once and stayed up: start requested 10:52:26, main process 10:52:30, `NRestarts=0`, `Result=success`
- i.e. the `ExecStartPre` poll absorbed a four-second wait for the address instead of burning the
start limit on it.

**Status:** Resolved (drop-in installed 2026-06-25, cold-boot verified 2026-08-13). Note the
drop-in still hard-codes the Tailscale IP inline rather than calling the shared
`wait-for-tailscale-ip.sh`; harmless, tracked in [KE-18](#ke-18)

**References:**
- [ADR - pveproxy Tailscale boot ordering](../decisions/pveproxy-tailscale-boot-ordering.md)
- [Runbook - pveproxy boot-race recovery](../../runbooks/platform/pveproxy-tailscale-boot-race.md)
- [Proxmox Host](./proxmox-host.md)

---

<a id="ke-13"></a>

## KE-13: aux-disk physical disk failure (medium errors)

**Affected component:** Proxmox host - aux-disk auxiliary disk (`/mnt/aux-disk`)

**Symptom:**
aux-disk will not mount on boot; five LXCs (LXC200/211/220/230/260) fail to start
because their Docker data-root bind-mount sources under `/mnt/aux-disk` are missing.
Earlier, the same mount failure dropped the host into emergency mode (the original
lockout).

**Root cause:**
Unrecoverable hardware medium errors on the disk (a consumer-grade drive,
~6.5 years power-on) - not a filesystem-only or cabling fault. Verified in the
kernel log (`critical medium error ... Unrecovered read error`) and SMART
(`Current_Pending_Sector` = `Offline_Uncorrectable` = 7688, `Reported_Uncorrect`
= 18). A read-only mount (`mount -o ro,noload`, no journal replay) still succeeded,
so the live data was recoverable.

**Fix / mitigation:**
`nofail` on the aux-disk fstab entry keeps the boot out of emergency mode (already in
place). All live data was rescued read-only before any repair attempt -
per-directory `tar --numeric-owner --ignore-failed-read` streamed to the admin
workstation, 12 archives (tens of GB), all integrity-verified, 0 real read errors. This
invalidates the `docker-data-root-migration` runbook and CLAUDE.md "Adding a New Service"
step 6, which both target `/mnt/aux-disk`.

The sentence "disk to be decommissioned; affected services not yet restored" stood here until
2026-08-13 and had been wrong since the disk went back into service - see the Status below,
which is the authoritative half of this entry. Verified 2026-08-13: the aux-disk is mounted and
carries the five container data-roots as described.

**Status:** Diagnosed; data rescued; disk returned to service under protest pending a
replacement. The disk carries the Docker
data-roots of LXC200/211/220/230/260 again - and VM100's `scsi1` data disk - because
no alternative target exists: the MergerFS pool on VM102 has a low-hundreds-of-GB free, and the LVM
thin pool on the boot SSD has no headroom.

**Degradation stopped after the first two weeks and has been static since.** SMART re-reads
(identify the disk by `by-id`, not by kernel letter - see the note in [KE-14](#ke-14)):

| Attribute | 2026-06-25 | 2026-07-09 | 2026-07-28 | 2026-08-13 |
|---|---|---|---|---|
| `Current_Pending_Sector` | 7688 | 7680 | 7680 | 7680 |
| `Offline_Uncorrectable` | 7688 | 7680 | 7680 | 7680 |
| `Reallocated_Sector_Ct` | 0 | 0 | 0 | 0 |
| `Reported_Uncorrect` | 18 | **21** | 21 | 21 |

`Reported_Uncorrect` rose by 3 in the first fortnight back in service and has **not moved in the
35 days since**. The 8 sectors that left `pending` were rewritten and proved usable; none were
reallocated, so the drive's spare pool is untouched and the remaining 7680 sectors hold data
that cannot be read back.

**Static is not safe, and it is not "recovered".** Those 7680 sectors are still unreadable; the
drive has simply not been asked to read them again. What the flat curve does change is urgency:
replacement is a planned task, not an emergency. Do not read `smartctl -H` as a second
opinion - measured again 2026-08-13, it returns `PASSED` on this disk, because
`Current_Pending_Sector` normalises to `VALUE=054` against `THRESH=000` and can therefore never
trip the self-assessment. The textfile collector on the host inherits that blindness verbatim:
it exports `smart_health_passed{disk=...} 1` for this drive and nothing else that would contradict
it (see the SMART gap in [`operations.md`](./operations.md)).

**What is at stake** (measured 2026-07-09, ~20% of the disk used):

| Path | Used |
|---|---|
| `images/` - VM100's `scsi1` (300 G apparent, sparse) | 106 G |
| `Archiv/` | 45 G |
| `openwebui/`, `paperless/`, `monitoring/`, `calibreweb/` | 31 G combined |
| `postgres/`, `nextcloud/` | 247 M combined |

`vm-disks/vm100-jellyfin.raw` claims 300 G but allocates 8 K and is referenced by no guest
config - an orphan from January, left in place.

Consequences while the disk remains in service:

- **Do not run `docker-compose-update` against the fleet.** Pulling new images writes
  gigabytes of new blocks onto this disk. Image pins can wait for the replacement.
- Treat anything on `/mnt/aux-disk` as unbacked. It has no off-site copy.
- Disk identity for the physical swap: `<disk-model>`, serial `<disk-serial>`,
  the aux disk (AHCI `ata6.00`).

### Follow-up finding (2026-07-09): the disk was simultaneously host-mounted and passed through to VM102

Discovered while mapping the disk topology. The aux-disk's single partition was mounted `rw` on
the Proxmox host at `/mnt/aux-disk` and attached to the running VM102 as `scsi8`
(`/dev/disk/by-id/<aux-disk-by-id>`), confirmed against the live `kvm`
process arguments, not just `qm config`. Both refer to the same filesystem - UUID
`<fs-uuid>` appears in the host's `EXT4-fs ... mounted filesystem`
line and as VM102's a member disk.

VM102 did not mount it: its `/etc/fstab` entry had been commented out when the disk moved
to the host after the 2026-06-25 incident, but the passthrough was never removed from the VM
config. No corruption resulted. Had anything in VM102 mounted a member disk - an uncommented
fstab line, a manual `mount`, a rebuild from an older fstab - two kernels would have written
to one ext4 with no locking between them. ext4 is not a cluster filesystem; the outcome would
have been metadata corruption, not a race that can be won.

This is a plausible contributing factor to the original 2026-06-25 mount failure and
emergency-mode lockout, though not a substitute explanation: the 7680 unreadable sectors are
drive-reported and independent of any mount topology.

Fix applied 2026-07-09 (live):

1. `qm set 102 --delete scsi8` - hot-unplug of the passthrough. VM102 held no mount, no open
   file handle, no LVM PV and no md member on the device, all verified before the change. The
   guest logged the expected `Synchronize Cache(10) failed ... DID_BAD_TARGET` (the device was
   gone before the cache flush; nothing was dirty). Proxmox removed the config line without
   creating an `unusedN` entry, because a raw device path is not a storage-managed volume -
   no data was touched.
   Reversal: `qm set 102 --scsi8 /dev/disk/by-id/<aux-disk-by-id>,size=<size>`
2. VM102's commented `/etc/fstab` line replaced with an explicit four-line warning naming the
   host mount and the corruption consequence. A bare `#` documents nothing; the next person to
   tidy up would have uncommented it. Backup at `/etc/fstab.bak-<date>`; `findmnt --verify`
   clean; `systemctl daemon-reload` run.

### Related latent fault (not fixed): `appdata_aux-disk` storage lacks `is_mountpoint 1`

The directory storage in `/etc/pve/storage.cfg` declares `path /mnt/aux-disk` and `mkdir 0`, but
not `is_mountpoint 1`. `mkdir 0` stops Proxmox from *creating* the path; it does not stop it
from *writing into* an existing empty mountpoint. If aux-disk fails to mount at boot - as it did
on 2026-06-25 - Proxmox considers the storage active and writes VM100's disk into `pve-root`
on the boot SSD, filling it. That is the KE-7 failure class. Deferred with all other Proxmox
host changes.

**References:**
- [Incident write-up - aux-disk failure and recovery](./incidents/2026-06-25-aux-disk-failure-and-recovery.md)
- [Runbook - aux-disk failure rescue](../../runbooks/storage/aux-disk-failure-rescue.md)
- [VM100 node doc](../nodes/vm100.md)
- [VM102 node doc](../nodes/vm102.md)
- [KE-7: Package corruption when LVM thin-pool overflows](#ke-7-package-corruption-when-lvm-thin-pool-overflows-during-apt-upgrade)

---

<a id="ke-14"></a>

## KE-14: Intermittent boot-time I/O errors on the boot SSD (SAS HBA transport, not media)

**Affected component:** Proxmox host - the boot SSD behind the LSI SAS2008 HBA
(`scsi 9:0:0:0`, `phy(3)`, driver `mpt2sas`, `/dev/disk/by-id/<boot-ssd-by-id>`)

> **Do not identify this disk by its kernel letter.** `sd*` names are assigned in probe order and
> change between boots: this entry documented `sdc` throughout July 2026, and on the 2026-08-13
> boot the same disk came up as `sda`. Identify it by the SCSI address `9:0:0:0` or by `by-id`;
> both are stable. The same applies to the aux-disk of [KE-13](#ke-13). This is the KE-15 lesson
> one layer down - a name that *looks* like an identifier but only describes a position.

**Symptom:**
On some boots the kernel logs a burst of read failures against the boot SSD roughly three
minutes after start, then falls silent (`<boot-ssd>` below is whatever letter that boot
assigned):

```
sd 9:0:0:0: [<boot-ssd>] tag#628 FAILED Result: hostbyte=DID_SOFT_ERROR driverbyte=DRIVER_OK cmd_age=19s
sd 9:0:0:0: [<boot-ssd>] tag#628 CDB: Read(10) 28 00 07 7c 0e 60 00 00 18 00
I/O error, dev <boot-ssd>, sector 125570656 op 0x0:(READ) flags 0x80700 phys_seg 3 prio class 2
```

The disk carries `/boot/efi`, `pve-root`, and the entire `pve-data` thin pool - i.e. the root
disks of every VM and LXC on the host. No filesystem damage has resulted so far (no
`EXT4-fs error`, no read-only remount).

Observed frequency (persistent journal, `journalctl -k -b <n>`):

| Boot | Date | Error lines |
|---|---|---|
| - | 2026-08-13 10:52 | 2 |
| - | 2026-08-10 08:36 | 0 |
| 0 | 2026-07-09 07:38 | 11 |
| -1 | 2026-07-08 10:44 | 0 |
| -2 | 2026-07-06 16:10 | 20 |
| -3 | 2026-07-05 07:31 | 0 |

Errors occur only during the boot window and never afterwards; the 11 errors of 2026-07-09 hit
11 distinct sectors, so no single block is repeatedly unreadable. The fault is still live:
the 2026-08-13 boot produced `cmd_age=29s` at boot + 3 min while the preceding boot was clean,
which is the documented on/off pattern rather than a drift toward failure.

**Root cause:** *Not yet confirmed.* What has been ruled out:

- **Not media failure.** `DID_SOFT_ERROR` is the host adapter reporting a transient fault. A
  genuine bad sector produces `hostbyte=DID_OK driverbyte=DRIVER_SENSE` with
  `Sense Key: Medium Error` / `Add. Sense: Unrecovered read error`. There is no sense data
  here. The drive's own SMART error log reads `No Errors Logged`, and every media counter is
  zero (`Reallocated_Sector_Ct`, `Runtime_Bad_Block`, `Program_Fail_Cnt_Total`,
  `Erase_Fail_Count_Total`). `cmd_age=19s` is a command timeout, not a read failure - a drive
  that cannot read a sector reports so in milliseconds.
- **Not HBA firmware.** `FWVersion(20.00.07.00)` is the known-good P20 phase; the problematic
  phases are 20.00.00.00 through 20.00.04.00.
- **Not the SATA controller.** The boot SSD is not on AHCI at all. It hangs off the SAS2008
  (`scsi target9:0:0`, `phy(3)`, driver `mpt2sas`); the only AHCI devices on this host are the
  two auxiliary disks (`ata5.00` and `ata6.00`, the latter being the KE-13 aux-disk). Confirmed
  again 2026-08-13 with `lsblk -dno NAME,TRAN`: the boot SSD reports `sas`, the aux-disk `sata`.

Leading hypothesis: 12 V rail sag under peak boot load. Boot is the moment of maximum draw
- two mechanical drives spin up simultaneously (spindle inrush current is several times the
running current), the HBA initialises, guests start. `sensors` reports `+12V Voltage: 10.03 V`,
which is 16% below nominal and outside the ATX +/-5% tolerance (11.4-12.6 V). This is consistent
with the timing, but unverified: motherboard voltage sensors - `asus_wmi_sensors` in
particular - are frequently inaccurate or mislabelled, and `AIO Pump: 0 RPM` in the same output
suggests some channels are reading unconnected headers. The SAS2008 is also passively cooled
and known to run hot without forced airflow, which remains a plausible alternative.

**Verification steps (physical, not yet performed):**

1. Multimeter on a spare Molex/SATA power connector, yellow to black, at idle and during boot.
   A real ~12 V reading falsifies the sensor and closes this lead.
2. Reseat the SAS cable at both the HBA and `phy(3)`.
3. Check the SAS2008 heatsink temperature (host powered off, by hand). If hot, fit a 40 mm fan
   - the standard remedy for this controller in desktop chassis.
4. Establish PSU model and age. The drives report ~6.6 years power-on; a PSU of the same
   vintage with aged capacitors would explain a sagging 12 V rail.

**Fix / mitigation:** None applied. The fault is currently self-limiting (boot window only, no
filesystem damage). The risk is that an `EIO` returned into the thin pool during guest start
could corrupt a guest filesystem.

**Status:** Diagnosed to transport layer; media and firmware causes excluded; physical root
cause unconfirmed pending the verification steps above. Re-confirmed live on 2026-08-13 - the
fault has not resolved itself and none of the four verification steps has been performed.

**Incidental correction:** all nine disks are attached to the Proxmox host. VM102 reaches
six of them through `/dev/disk/by-id/` passthrough and sees only virtio-SCSI devices, so SMART
data is readable *only on the host*. Any SMART monitoring must therefore run there, not on
VM102 as previously documented.

**References:**
- [Proxmox Host](./proxmox-host.md)
- [KE-13 - aux-disk physical disk failure](#ke-13) (a separate, genuine media failure on the aux-disk, which is an AHCI device and not behind the HBA; do not conflate)

---

<a id="ke-15"></a>

## KE-15: Guard tests mount existence, not mount identity - calibre-import dead for a month

**Affected component:** LXC220 (Calibre-Web) - `calibre-import.service`, the `calibre_importer`
role, and `snippets/scripts/calibre-import.sh`

**Symptom:**
`calibre-import.service` fails every 2 minutes (the timer interval) and has done so since
2026-06-08. No dropped ebook has been imported in that window. Nothing alerted.

```
calibre-import.sh[3904]: mkdir: cannot create directory '/books-rw/_import': Permission denied
systemd[1]: calibre-import.service: Main process exited, code=exited, status=1/FAILURE
```

**Root cause:** a four-step chain, each step individually unremarkable:

1. On the Proxmox host, the rw CIFS mount `/mnt/smb/books-rw` (`//vm102/Books`) is **not
   mounted**. This is the documented CIFS boot-race, except it is not transient - it has
   persisted for a month.
2. The `mp2` bind still maps the host path into LXC220 as `/books-rw`. With the CIFS mount
   absent, the bind exposes the empty directory *underneath* it, on `pve-root`.
3. That directory is owned by host root. LXC220 is an unprivileged container, so host UID 0
   appears inside as `65534` (`nobody`). With mode `0755`, container root cannot write to it.
4. `mkdir -p "${FAILED_DIR}"` fails with `EACCES`; `set -euo pipefail` aborts the script with
   exit 1.

**Why both guards failed to catch it:**

The script (line 49) and the Ansible role each guarded with:

```bash
mountpoint -q /books-rw
```

This returns success. `/books-rw` is a mountpoint - the `mp2` bind itself is one, whether or
not the CIFS mount underneath the host path succeeded. The guard tested the *existence* of a
mount and could not, in principle, detect a *substituted* one. It was blind to exactly the
failure class it was written for.

This is the same structural error as `appdata_aux-disk` lacking `is_mountpoint 1`: a check that
asserts a path exists, where what matters is what is mounted at it.

Compounding it, the Ansible guard was an `ansible.builtin.command` without `check_mode: false`,
so `--check` skipped it. A dry-run reported the role healthy.

**Fix (applied 2026-07-10, repo side):**

- Both guards now test the mount's *identity*, not its existence: `findmnt -no FSTYPE /books-rw`
  must return `cifs`. A healthy bind of a CIFS mount reports `cifs` inside the container; the
  failed one reports `ext4` (pve-root). A second guard requires `metadata.db` to be present,
  covering the "right fstype, wrong share" case.
- The script now exits 1, not 0, when the library is absent. The previous `exit 0` was a
  deliberate no-op ("VM102/network down") and is precisely why a month of failure stayed
  invisible. Transient absence during the boot window is absorbed by the alert rule's `for:`
  window, not by silencing the script.
- The role's probe carries `check_mode: false` so it also runs during `--check`, and the task
  order was changed to deploy the script and units *before* asserting the mount - otherwise a
  broken host mount blocks delivery of the script that handles broken host mounts.

**Host-side root cause found and fixed (2026-07-14) - it was never "a boot race that stuck":**

The host mount did not fail *randomly*. It failed deterministically, at every boot, and the
`/etc/fstab` line says why:

```
# working sibling (read-only)
//<lan-ip-vm102>/Books-service  /mnt/smb/books     cifs  _netdev,nofail,x-systemd.automount,...
# broken (read-write)
//<lan-ip-vm102>/Books          /mnt/smb/books-rw  cifs  _netdev,nofail,noatime,...
```

`books-rw` lacked `x-systemd.automount`. Without it, systemd mounts the share once, during
boot, and if that attempt fails it is never retried - `nofail` lets the boot proceed and the unit
stays `failed` forever. The journal shows the same line at every single boot:

```
mount error(113): could not connect to <lan-ip-vm102> - Unable to find suitable address.
```

The reason it cannot succeed at boot is structural, and it is why no amount of ordering would have
helped: **the Proxmox host is mounting a share from a VM that the host itself has not started
yet.** Boot timeline of 2026-07-14:

| Time | Event |
|---|---|
| 12:16:15 | `trigger-smb.mounts.service` starts (the "boot stabilization" unit) |
| 12:16:22 | `pve-guests.service` starts |
| 12:16:23 | VM102 is started - the SMB server only comes up now |
| 12:18:37 | CT220 starts |

`x-systemd.automount` is what makes the sibling work: the mount is established lazily, on first
access, and the first access happens when Proxmox sets up the container's bind - by then VM102 has
been up for two minutes. Proven on the live host: with `noatime` replaced by
`x-systemd.automount,x-systemd.mount-timeout=30,noatime`, `/mnt/smb/books-rw` now reports
`autofs` + `cifs` stacked, exactly like `/mnt/smb/books`.

**Side finding, fixed the same day - the "boot stabilization" service was cargo cult.**
`trigger-smb.mounts.service` ran *before* `pve-guests` starts VM102, so it poked automounts whose
server did not exist yet, and its script swallowed every error (`timeout 3s ls ... || true`), so it
always reported success. Removed and replaced by `smb-mounts-check.service`, which runs
`After=pve-guests.service` and exits 1 if any `/mnt/smb/*` path is not `cifs`. Its prerequisite
was fixed too: the host's `node_exporter` had no `--collector.systemd`, so a failed unit on the
host reached no alert. Both verified, including the negative case. See
[runbook](../../runbooks/storage/smb-autofs-trigger.md).

**Verification (2026-07-14):**

- Container bind before `pct reboot 220`: `/books-rw` -> `ext4 /dev/mapper/pve-root[...]` - the
  KE-15 signature, the empty directory on the boot SSD.
- After the reboot: `/books-rw` -> `cifs //<lan-ip-vm102>/Books`, and a write as container root
  succeeds.
- `calibre-import.service`: `Result=success`, exit 0. Two consecutive timer runs finished cleanly
  (12:19:10, 12:20:12 UTC); the last failure was 12:17:32, before the fix. **lxc220 now has no
  failed unit at all.**
- The `findmnt -no FSTYPE` guard added on 2026-07-10 now passes for the right reason rather than
  failing for the right reason.

**Proven across a host reboot (2026-08-13).** All seven `/mnt/smb/*` fstab entries carry
`x-systemd.automount` and every one resolves to `cifs`; the `books-rw` automount included.
`smb-mounts-check.service` reports `Result=success` / exit 0, `calibre-import.service` on lxc220
likewise, and `findmnt -no FSTYPE /books-rw` inside the container returns `cifs` - the identity
test, not the existence test. The fstab audit
(`grep '/mnt/smb/' /etc/fstab | grep -v x-systemd.automount`) prints nothing.

**The gap that let it run for a month (closed 2026-07-10):** a `failed` systemd unit raised no
alert. Monitoring covered `NodeDown` (node_exporter), disk fill, and `ServiceDown` (blackbox HTTP
probes); a unit that fails 20,000 times fits none of those. This was the KE-8 blind spot one level
deeper. Remediated the same day: `node_exporter --collector.systemd` (with `.mount` units kept in
scope - the stock exclude drops them, and this fault *is* a mount fault) plus the
`SystemdUnitFailed` Prometheus rule. Verified: lxc220 now exports
`node_systemd_unit_state{name="calibre-import.service",state="failed"} 1` and Prometheus raises
the alert.

**Status:** RESOLVED 2026-07-14. Root cause confirmed on both sides: the guard was blind
(fixed 2026-07-10), and the host mount lacked `x-systemd.automount`, so a mount against a VM the
host had not yet started failed once at boot and was never retried (fixed 2026-07-14). Import path
restored and verified; lxc220 has no failed unit. Closed 2026-08-13 - confirmed across a real
host power cycle, see above.

**References:**
- [LXC220 node doc](../nodes/lxc220.md)
- [ADR - Calibre CIFS SQLite import](../decisions/calibre-cifs-sqlite-import.md)
- [KE-8 - observability blind spot](#ke-8)
- [KE-13 - the `appdata_aux-disk` `is_mountpoint` note](#ke-13) (same structural error: a check that asserts a path exists where what matters is what is mounted at it)

---

<a id="ke-16"></a>

## KE-16: Apache serves an expired certificate that was already renewed on disk

**Affected component:** LXC210 (Nextcloud) - Apache + the Tailscale-issued TLS certificate

**Symptom:**
`ServiceDown` fired for `nextcloud` on 2026-07-10. The blackbox probe reported
`probe_success = 0`; `curl` against the same URL returned `http=000` with
`ssl_verify_result=10` (`X509_V_ERR_CERT_HAS_EXPIRED`) and exit 60. With `-k` (verification
disabled) the same URL answered `302`. Apache, MariaDB, Redis and PHP-FPM were all `active`.

**Root cause:**
The certificate Apache was *serving* had `notAfter=Jul 10 09:53:15 2026 GMT` - it had expired
about an hour earlier. The certificate *on disk* at `/var/lib/tailscale/certs/` was valid from
`Jul 10 09:38:32` to `Oct 8 09:38:31`.

`tailscaled` had renewed the file fifteen minutes before the old one expired. **Renewal was never
the problem.** Apache reads its certificate at start-up and holds it in memory; nothing told it
to re-read. It went on presenting the April certificate from RAM while a valid one sat on disk
beside it.

Why only this node: the other five certificate-holding nodes (lxc200, lxc211, lxc220, lxc230,
lxc240) terminate TLS through `tailscale serve`, which asks `tailscaled` for the certificate per
connection - renewal is transparent there. LXC210 is the only node whose service reads the file
directly, via `SSLCertificateFile /var/lib/tailscale/certs/<fqdn>.crt` in
`sites-available/nextcloud-ssl.conf`.

**Immediate fix (applied 2026-07-10):** `tailscale cert --cert-file ... --key-file ...
--min-validity 720h <fqdn>` (reported "unchanged", confirming tailscaled had already renewed),
then `systemctl reload apache2`. Verified from the wire: the probe now returns `http=302` with
`ssl_verify=0`, and the served certificate is the October one.

**Durable fix (applied 2026-07-10):** new `tailscale_cert` role - `tailscale-cert-refresh.sh`
plus a daily systemd timer, targeted at the new inventory group `tailscale_cert_ondisk` (only
lxc210; serve-backed nodes must not be listed). The script hashes the certificate, runs
`tailscale cert --min-validity 720h` (a no-op while more than 30 days remain, so a daily run
costs nothing), and reloads Apache only if the hash changed. `reload`, not `restart`: Apache
re-reads certificates on a graceful reload and live connections survive. The timer carries
`Persistent=true`, because the host is powered down overnight and a fixed nightly slot would
simply be missed.

Verified: timer `active`/`enabled`; a manual run of the service logs
`certificate unchanged (valid for at least 720h) - no reload needed` and exits 0. The reload
branch was not exercised against a real renewal - forcing one would consume a Let's Encrypt rate
limit to re-prove a `systemctl reload apache2` that had already succeeded minutes earlier.

**Note:** the detection worked. `ServiceDown` fired within minutes of the expiry and reached
Discord. The gap was that nothing acted on it, and nothing prevented the recurrence that would
have happened again on 8 October.

**Related, not fixed:** Apache on lxc210 listens on `*:80` and `*:443`, i.e. on the LAN
interface, violating the platform binding rule - the same defect class as vm100's sshd. MariaDB
and Redis on the same node bind single addresses correctly. Re-confirmed live 2026-08-13: both
wildcard listeners are still present.

**References:**
- [LXC210 node doc](../nodes/lxc210.md)
- [Nextcloud service doc](../services/nextcloud.md)
- [KE-8 - the blind spot this alert closed](#ke-8)

---

<a id="ke-17"></a>
## KE-17: VM100 silent guest hard-freeze - no logged root cause, recovered by hard power-cycle

**Affected component:** VM100 (GPU / NVIDIA-passthrough node, Ubuntu 22.04.5, kernel
`5.15.0-185-generic`) - the guest OS, not the hypervisor.

**Symptom:**
On 2026-07-11 vm100 was unreachable over SSH and Tailscale. `ssh gpu` hung at the TCP-connect
stage - no `Connection refused`, no auth prompt - placing the fault in the reachability class, not
a bind or key fault. `tailscale status` showed the node `offline, last seen 8h ago, tx ... rx 0`:
the host was sending into the tunnel and getting nothing back. `qm status 100` reported
`running`, but that only means the hypervisor is scheduling the vCPU and says nothing about guest
health. A WebUI reboot returned `QEMU Guest Agent is not running - guest-ping ... got timeout` and
`VM quit/powerdown failed - got timeout`: both the guest agent and ACPI were unresponsive. The
serial console (`qm terminal 100`) was completely blank - no login prompt, no echo on Enter, no
panic trace. The guest was hard-frozen.

**Root cause:** Undetermined from logs - named as such rather than guessed. What the evidence
rules in and out:

- The guest's own journal (`journalctl -b -1`) ends abruptly at `01:41:13 UTC` mid-normal-operation,
  with no shutdown sequence (`Stopping...` / `Reached target Shutdown` absent). That is the signature
  of a freeze so hard journald could not write another line - not a reboot. A kernel-signature grep
  (`oom|hung task|soft lockup|BUG:|call trace|watchdog`) over that boot returned only the benign
  boot-time `NMI watchdog: Enabled` line. No OOM, no lockup, no panic was logged inside the guest.
- The host was healthy at the freeze moment. `01:41:13 UTC = 03:41:13 CEST` (see the timeline
  caveat). The host journal for 03:30-03:50 CEST holds no `kvm` / `vfio` / `nvidia` / `oom` /
  VMID-100 message, and the `node-exporter-smarttext` SMART collector completed successfully at
  03:41:14-16. This is not KE-14 - the host disk / HBA layer threw nothing.

So: a silent, guest-internal hard freeze on a node that does NVIDIA GPU passthrough and already
carries an intermittent NVIDIA/CUDA fault (KE-10). A causal link to KE-10 is plausible but unproven.

**Timeline caveat (load-bearing):** the guest clock is `Etc/UTC`, the host clock is
`Europe/Berlin` (CEST, +2h). Read naively, the guest's last line (`01:41`) falls inside the host's
nightly power-off gap - host boot -1 ended `01:01:10 CEST`, boot 0 began `01:58:09 CEST` - which is
impossible, since the guest cannot log while the host is off. The +2h offset resolves it: the
freeze was `03:41 CEST`, well inside host boot 0. The host was up off-schedule because the admin
had powered it on manually for night work and gone to sleep before the freeze; this is not a
`homelab_schedule` defect.

**Immediate fix (applied 2026-07-11):** graceful recovery was already exhausted (QGA guest-ping
and ACPI powerdown both timed out), so a hard power-cycle - `qm stop 100` (QMP quit attempt, then
the QEMU process is killed, the plug-pull equivalent) followed by `qm start 100`. The node returned
to `active; direct` within ~2 min; the clean host disk layer made the unclean-shutdown journal
replay low-risk. All alerts resolved at 11:45 CEST.

**Detection worked; response did not.** `NodeDown` fired at 03:45 CEST - ~4 min after the freeze,
after >2 min of failed scrapes - alongside `ServiceDown` for jellyfin and audiobookshelf
(independent blackbox probes). The alerts stayed firing for ~8 h and re-notified at 07:50. The gap
was purely human: the alert reached Discord at 03:45 while the admin slept, and there is no
overnight escalation and no auto-recovery. For a hobby media node, an auto-recovering watchdog is
the proportionate fix, not a 03:45 page.

**Durable fix - not yet applied (follow-ups):**

- Auto-recovery: a QEMU watchdog device (`i6300esb`) plus `softdog` in the guest would reset a
  wedged guest automatically instead of leaving it dead for 8 h. The in-guest **NMI watchdog is not
  a substitute** - it depends on hardware PMU counters that are unreliably virtualized under KVM,
  which is why it caught nothing here.
- Post-mortem forensics that survive the freeze: `kdump` / `pstore` to capture a panic trace next
  time, since the live console and journal yield nothing after a hard freeze.
- Recurrence is unquantified - this is the first recorded occurrence. If it repeats, escalate to a
  real investigation (candidate: the KE-10 NVIDIA path).

**References:**
- [VM100 node doc](../nodes/vm100.md)
- [Incident record - 2026-07-11 vm100 silent freeze](incidents/2026-07-11-vm100-silent-freeze.md)
- [KE-10 - Jellyfin loses CUDA access (same node, NVIDIA path)](#ke-10)
- [KE-14 - boot-SSD I/O errors (excluded here)](#ke-14)
- [KE-8 - the observability model that caught this](#ke-8)

---

<a id="ke-18"></a>

## KE-18: Services start before Tailscale is ready (ordering is not readiness)

**Affected:** platform-wide class. Start here when a service that binds or queries a Tailscale
resource fails during the boot window, before opening the per-service entries below.

**Why this entry exists:** the platform binding rule requires services to bind their Tailscale IP
rather than `0.0.0.0`. The rule is right, but it makes those services depend on a resource that does
not exist yet at boot. The same fault has now been diagnosed from scratch four times. This entry
records the shape once so the fifth is a lookup rather than an investigation.

**Symptom:** during the boot window only - a manual start afterwards always succeeds.

```
bind: cannot assign requested address        # kernel EADDRNOTAVAIL
could not determine the node's MagicDNS name # the query-time variant
```

### Why `After=tailscaled.service` is not enough

`After=` orders the unit after tailscaled has started, and systemd considers a `Type=simple`
service started the moment its process is alive. Joining the tailnet, negotiating with the control
plane and assigning an address all happen *afterwards*. Ordering guarantees sequence, not
readiness - the unit must poll for the resource it actually needs.

The second, quieter half is systemd's restart rate limiter. `Restart=on-failure` with the default
`RestartSec=100ms` means five attempts inside ~24 ms; `StartLimitBurst` is then exhausted and the
unit stays dead until someone intervenes. A rapid-restart loop is not a retry strategy - it is a
way to convert a two-second race into a permanent outage.

### Instances

| Node / unit | Variant | Status |
|---|---|---|
| lxc260 `postgresql@15-main` | bind | Fixed 2026-06-09 - [KE-9](#ke-9), `postgresql-boot-order` role |
| host `pveproxy` | bind | Fixed 2026-06-25 - [KE-12](#ke-12), `wait-tailscale.conf` drop-in |
| host `node_exporter` | bind | Fixed 2026-07-28 (below) |
| lxc210 `tailscale-cert-refresh` | query | Fixed 2026-07-28 (below) |

**What makes this platform unusually exposed:** `homelab-schedule` powers the host down at 01:00 and
wakes it by RTC in the morning, so every day is a cold boot. Timers that carry `Persistent=true`
to catch up runs missed overnight therefore fire *inside the boot window* by design - that is how
the lxc210 certificate job became a boot-time job without anyone choosing that. On this platform the
boot window is a routine execution context, not an edge case.

### Instance: host `node_exporter` (found and fixed 2026-07-28)

A regression introduced by `54402ed` (2026-07-14), which moved the host's `node_exporter` from a
wildcard bind to `--web.listen-address=<tailscale-ip-proxmox-host>:9100` - correct per the binding
rule, but it placed the unit into this failure class. It had failed at every boot since, i.e. daily,
and the failure hid itself: the host's own down-ness is exactly what stops it from being reported.
`NodeDown` did fire, and was read as a stale artifact of the nightly power cycle.

Diagnosis: `Active: failed`, `Duration: 24ms`, `Start request repeated too quickly`, restart counter
at 5.

Fix: `/usr/local/bin/wait-for-tailscale-ip.sh` (copied from lxc260, unchanged - it derives the
address via `tailscale ip -4` rather than hard-coding it) plus a drop-in at
`/etc/systemd/system/node_exporter.service.d/wait-tailscale.conf` with
`ExecStartPre=/usr/local/bin/wait-for-tailscale-ip.sh 90` and `RestartSec=5`.

Verified: `ExecStartPre` `status=0/SUCCESS`, listening on `:9100`, Prometheus target `health: up`
with an empty `lastError`, `NodeDown` cleared.

**Cold-boot verified 2026-08-13**, and the gate demonstrably did work rather than merely being
present - the journal of that boot reads:

```
10:52:24  Starting node_exporter.service ...
10:52:30  wait-for-tailscale-ip: <tailscale-ip-proxmox-host> present after 6s
10:52:30  Started node_exporter.service
```

Six seconds of real waiting, `NRestarts=0`. Without the gate the bind would have been attempted at
10:52:24 against an address that did not exist until 10:52:30 - the original failure, exactly.

### Instance: lxc210 `tailscale-cert-refresh` (found and fixed 2026-07-28)

The query-time variant: the unit does not bind anything, it *asks* tailscaled for the node's
MagicDNS name (`tailscale status --json` -> `Self.DNSName`) and derives the certificate paths from
it. At boot that field is still empty, so under `set -euo pipefail` the script exited 1 - on every
boot from at least 2026-07-26 onward, and most likely on every boot-triggered run ever. Renewal was
therefore never running; the certificate happened to be valid until 2026-10-08, so nothing had
broken yet. See [KE-16](#ke-16) for what happens when that certificate does go stale.

Fix: the FQDN derivation in `snippets/scripts/tailscale-cert-refresh.sh` now polls for up to 90 s
instead of reading once, with `|| true` inside the loop so `pipefail` cannot abort the script while
tailscaled is still starting.

Verified 2026-07-28: `Result=success`, `ExecMainStatus=0`, no failed unit anywhere in the fleet,
certificate untouched (`no reload needed`, still `notAfter=Oct 8 2026`). That run happened with
tailscaled already up, so it exercised only the normal path.

**The race path itself is now proven (2026-08-13).** The host booted at 08:52:21 UTC and the
`Persistent=true` catch-up fired the overdue 04:30 job at **08:53:43 - 82 seconds into the boot
window**, precisely the condition that used to fail. The unit finished at 08:53:54 with
`ExecMainStatus=0`: the FQDN poll spent 11 seconds waiting for `Self.DNSName` to become
non-empty and then proceeded normally (`certificate unchanged ... no reload needed`). This is the
one instance in this class whose fix could not be proven by a warm restart, and it has now been
exercised by the boot window it was written for.

### Fix shapes

- **Bind-time** (a service binds the address): gate the unit with
  `ExecStartPre=/usr/local/bin/wait-for-tailscale-ip.sh <timeout>`, plus `RestartSec` well above the
  default so a later tailscaled blip cannot exhaust the start limit in milliseconds.
- **Query-time** (a script reads a value from tailscaled): poll for the value inside the script.
  An `ExecStartPre` that waits for the *IP* is not a correct proxy for the *DNS name* being known.

Prefer reusing `wait-for-tailscale-ip.sh` over writing shell into a unit file: systemd applies its
own `$`-expansion to `ExecStartPre=`, so an inline `for i in $(seq 1 30)` can silently degrade to a
zero-iteration loop that exits 0 without ever waiting - a gate that reports success while doing
nothing.

**Status:** Class documented 2026-07-28; all four known instances fixed and **all four cold-boot
confirmed on 2026-08-13** against a real host power cycle - including the lxc210 query-time
instance, whose retry path only a boot could exercise. Fleet state at that boot: no failed unit on
any node, 19/19 Prometheus targets up, no alert firing.

Two loose ends, neither a readiness fault:

- The host's `pveproxy` drop-in still hard-codes its Tailscale IP inline rather than calling the
  shared script - harmless today, worth folding into the same pattern on the next host pass.
- **A fifth instance remains unfixed:** lxc250's hand-written `ssh.service.d/override.conf` uses
  `After=` plus a `RestartSec=15s` retry loop instead of a readiness gate. It survives because the
  retry loop is slow enough to outlast the race, which is luck rather than design. See
  [lxc250 § Open Items](../nodes/lxc250.md#open-items-2026-07-28).

**References:**
- [KE-6 - userspace-networking](#ke-6-tailscale-userspace-networking-prevents-node_exporter-from-binding-to-tailscale-ip) - produces the *same* `EADDRNOTAVAIL` message from an unrelated cause; a restart fixes this class and does nothing for that one
- [KE-9 - PostgreSQL loopback-only bind](#ke-9)
- [KE-12 - pveproxy boot failure](#ke-12)
- [KE-16 - stale certificate served from memory](#ke-16)
- [ADR - PostgreSQL boot ordering](../decisions/postgresql-tailscale-boot-ordering.md)
- [ADR - pveproxy boot ordering](../decisions/pveproxy-tailscale-boot-ordering.md)

---

<a id="ke-19"></a>

## KE-19: A file that changes during a sync poisons the health signal of the whole array

**Affected:** vm102, SnapRAID. Start here when `SnapRAIDSyncStale` and `SystemdUnitFailed` fire
together for `snapraid-maintenance@sync.service` while the array itself looks fine.

**Why this entry exists:** the failure looks like a storage fault and is not one. The array was
fully in sync except for a log file nobody wants protected, and the alert said "no sync for more
than 26 hours".

**Symptom:** the sync runs to completion, saves and verifies every content file, and then exits 1.

```
Unexpected size change at file '/mnt/disk03/Nextcloud/nextcloud.log' from 3541768 to 3554509.
WARNING! You cannot modify files during a sync.
      14 file errors
       0 io errors
       0 data errors
WARNING! Unexpected file errors!
```

`0 io errors` and `0 data errors` are the discriminator: no media fault and no corruption. All
14 errors were the same file.

### Root cause

SnapRAID computes parity over the bytes it reads. A file that changes underneath a running sync
cannot be parity-protected, so SnapRAID fails that file, continues with the rest, and exits
non-zero at the end. Nextcloud writes its own application log inside the protected pool.

### Why it surfaces in the morning rather than at 23:00

The sync is scheduled for 23:00 precisely because nothing is active then. But `homelab_schedule`
powers the host down overnight, so the timer never fires at 23:00 - `Persistent=true` catches it up
**at the next boot**, in the morning, when the services are running again. The journal shows both
patterns: runs at 23:02 on nights the host stayed up, and at 07:34 / 09:30 / 10:09 after a
power-down.

**The catch-up semantics that fixed one failure created another.** They are still correct - a
backup-class job must be caught up - but the quiescence the 23:00 slot was chosen for is gone, and
nothing recorded that trade. Same shape as the `PostgreSQLBackupStale` finding: a property everyone
assumed still held after the mechanism underneath it changed.

### Why one log file breaks the signal for the whole array

`snapraid sync` exits 1 -> `set -e` in `snapraid-maintenance.sh` aborts -> the success metric is never
written -> `SnapRAIDSyncStale` fires, and `SystemdUnitFailed` alongside it. Parity was current for
everything except that log.

**A health signal that is all-or-nothing gets held hostage by its least important member.** Same
abstraction as `DiskSpaceCritical` firing 21 times for one fact ([changelog 2026-07-10](changelog.md))
and as `smart_health_passed` reading PASSED on a disk with 7680 unreadable sectors
([KE-13](#ke-13)): the measurement does not answer the question being asked of it.

### Fix

Exclude the volatile files. SnapRAID is built for archives of files that do not change, and the
config had excludes only for `*.tmp`, `*.bak`, `lost+found/`, `/tmp/` and `/cache/`.

```
exclude /Nextcloud/nextcloud.log
exclude /Nextcloud/nextcloud.log.*
exclude *.sqlite3-shm
exclude *.sqlite3-wal
exclude *.db-shm
exclude *.db-wal
exclude /Nextcloud/appdata_*/richdocuments/remoteData/
```

**A first attempt used `exclude *.log` and was wrong.** The next `diff` showed it also dropping four
static CD-rip logs out of the audiobook archive - files that never change and were never the
problem. The rule is exclude what changes, not what shares a suffix; an over-broad exclude
silently reduces coverage, which is the failure mode this whole entry is about, one layer up.

### The finding that outlives the incident

`diff` also reported `Vaultwarden/db.sqlite3-shm` and `-wal` inside the array. Those are SQLite side
files, ephemeral by definition, and parity over them captured at a different moment than the main
database is an inconsistent set - a reconstruction from it can be corrupt.

`db.sqlite3` itself deliberately stays in the array: imperfect protection beats none while
Vaultwarden has no consistent export at all. That export is remediation plan Tier 1 #3, and this is
the second, purely technical reason for it - the first being that parity does not survive deletion
or ransomware. See [`data-classification.md`](data-classification.md).

### Verification (2026-08-15)

Ordered deliberately, because `snapraid sync` has no rollback (see the rollback section of
[`snapraid-sync.md`](../../runbooks/storage/snapraid-sync.md)):

1. `snapraid diff` before touching anything: 2 added (both explainable - the day's PostgreSQL
   dump and the first MariaDB dump), 1 removed (retention), 5 updated. No unexplained deletion.
2. Excludes added, `diff` re-run: over-broad `*.log` caught, narrowed, re-run again - 0 updated,
   7 removed, every one accounted for.
3. `systemctl start snapraid-maintenance@sync.service` -> `Result=success`, `ExecMainStatus=0`.
4. `snapraid diff` -> No differences, every file equal.
5. Metric written, scraped, both alerts cleared. vm102 reports no failed units.

**Status:** Fixed 2026-08-15, and fully closed since. This entry read "Open: `/etc/snapraid.conf`
is hand-managed ... these excludes are lost on a rebuild of vm102" until 2026-08-17, by which time
it had stopped being true: the `snapraid_maintenance` role owns the exclude rules through a marked
`blockinfile` block, verified live on vm102 (`# BEGIN ANSIBLE MANAGED - exclude rules (KE-19)`).
The remediation plan had recorded the closure; this register had not. The disk, parity and content
layout above the block stays hand-written on purpose - it carries the real device labels that
Check 18 keeps out of version control, and it changes only when hardware does.

**References:** [runbooks/storage/snapraid-sync.md](../../runbooks/storage/snapraid-sync.md) -
[KE-13](#ke-13); [data-classification.md](data-classification.md)

<a id="ke-20"></a>

## KE-20: VM100 froze during a live CIFS unmount, no evidence recorded

**Affected component:** VM100 (compute node, GPU passthrough)

**Symptom:**
On 2026-08-16 at 19:20 UTC, `systemctl stop` on the two media `.mount` units wedged the guest.
SSH over Tailscale and ICMP over the LAN both stopped answering. QEMU reported the VM as running
with QMP responsive and memory allocated; the guest agent did not answer. ACPI shutdown timed out.
Only `qm stop` followed by `qm start` recovered it, costing roughly 25 minutes of Jellyfin and
Audiobookshelf.

**What the evidence shows, and what it does not:**
The journal of that boot ends at 19:20:39 UTC, inside the SSH session in which the command ran.
The last kernel message is at 19:20:17, the teardown of the two container veth interfaces from the
preceding `docker stop`. Nothing follows: no `CIFS VFS` error, no `task blocked for more than 120
seconds`, no call trace, no shutdown record. systemd logs `Unmounting ...` before it stops a mount
unit, and even that line is absent.

That rules out an ordinary userspace deadlock, which would have kept logging and would have
produced a blocked-task warning after two minutes. It points to a freeze below the logging layer.
It does not establish the cause, because nothing was recorded.

**Client-side evidence, recovered 2026-08-17.** The guest wrote nothing, but the other end of the
SSH session recorded how it died: `Read from remote host: Connection reset by peer`, exit 255 -
a reset, not a timeout. That is worth writing down and worth not over-reading. A reset means a RST
segment arrived, and there are two readings: the guest's network stack answered while the process
behind it was already gone, or - the likelier one - the RST came after `qm start`, when the
restarted guest received packets for a connection it knew nothing about. The second reading makes
the reset evidence of the recovery, not of the freeze. The two cannot be separated after the fact,
because the client's message carries no timestamp of its own.

The lesson is the one this file keeps relearning: an artefact recovered late is still worth
recording, and is still only worth what its timeline can prove. Attach a timestamped client-side
transcript to the next attempt, so this ambiguity does not repeat.

The Proxmox host logged no kernel message at all in that window, so the failing auxiliary disk
([KE-13](#ke-13)) is not implicated. One weak signal exists: between 17:01 and 17:15 UTC the guest
reported `perf: interrupt took too long` six times, lowering its sample rate from 78000 to 23750.
That is two hours earlier and proves nothing on its own.

**Root cause:** unknown.

**Why it was not pursued further:**
Reproducing it requires a rollback path, and VM100 has none. Its `scsi1` is a 300 GB raw file on
directory storage, which Proxmox cannot snapshot, and it sits on the KE-13 disk. The thin pool
holding `scsi0` is at 84 % with zero free space in the volume group. A repeat attempt would
therefore risk an unrecoverable guest for a change whose benefit was incremental.

**What was done instead:**
The operation was avoided rather than made safe. The media shares were rescoped by creating new
mount units on new paths, repointing the two `.env` files and recreating the containers; the old
automount units were only disabled, which drops the boot symlink without unmounting, leaving the
nightly power-off to retire them. Nothing was unmounted on a running system.

`netconsole` now streams the guest kernel log over UDP to the Proxmox host, so a repeat would
leave evidence even if disk writes stop. Note `console_loglevel` is 4, which filters
`INFO: task blocked` at priority 6 - it must be raised to 7 before any repeat attempt, or the
channel will be silent for exactly the message being sought.

**Open:**
- Cause unknown; do not schedule further live unmounts on VM100 until it can be rolled back.
- ~~`netconsole` and the loglevel are not persistent across a reboot.~~ Closed 2026-08-17. Both
  were gone after the nightly power cycle, as predicted: the module was not loaded and
  `console_loglevel` was back to 4, so the channel had been dead for a day without saying so. Now
  owned by the `netconsole` role on vm100 plus a hand-deployed receiver unit on the host. The unit
  is ordered `After=network-online.target` rather than listed in `/etc/modules-load.d/`, because
  the latter runs before the interface has an address and would fail into silence - see
  [KE-18](#ke-18).
- VM100 cannot be snapshotted at all. That is the precondition for investigating this.

---
