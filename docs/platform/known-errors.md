# Known Errors

Faults observed on this platform, their root cause, fix and current status. Generic failure
scenarios and response procedures are in [operations.md](./operations.md).

Every entry carries an explicit `<a id="ke-N"></a>` anchor; link to `known-errors.md#ke-N`, not to
the heading slug. Format: [CONVENTIONS.md](../CONVENTIONS.md#known-error-entry).

---

## Entries

| # | Fault | Status |
|---|---|---|
| [KE-1](#ke-1) | SQLite on CIFS - database is locked | Resolved - no database files on CIFS (architectural rule) |
| [KE-2](#ke-2) | Grafana datasource unreachable after host networking switch | Resolved |
| [KE-3](#ke-3) | Failed run-rpc_pipefs.mount in LXC210 | Resolved 2026-09-11 |
| [KE-4](#ke-4) | Docker creates directories for missing bind-mount files | Open - Docker design behaviour, manual recovery |
| [KE-5](#ke-5) | Vaultwarden SQLite on CIFS | Resolved 2026-09-01 by decommissioning |
| [KE-6](#ke-6) | Tailscale userspace networking prevents the exporter binding | Resolved 2026-07-28; stray unit removed 2026-09-01 |
| [KE-7](#ke-7) | Package corruption when the LVM thin pool overflows | Resolved 2026-04-26 |
| [KE-8](#ke-8) | Media services hang while the node stays healthy | Mitigated 2026-06-08 - service probes alert; cause not found |
| [KE-9](#ke-9) | PostgreSQL binds only loopback after boot | Resolved 2026-06-09 |
| [KE-10](#ke-10) | Jellyfin loses CUDA access intermittently | Mitigated - fault active, stream-aware watchdog restart |
| [KE-11](#ke-11) | Grafana admin password not updated after first start | Open - Grafana design behaviour, non-blocking |
| [KE-12](#ke-12) | pveproxy fails to start after boot | Resolved 2026-06-25; gate owned by `tailscale_boot_gate` since 2026-09-12 |
| [KE-13](#ke-13) | aux-disk physical failure | Open - degrading, in service, replacement planned |
| [KE-14](#ke-14) | Read commands to the boot SSD time out under load | Open - drive replacement in the second half of October 2026 |
| [KE-15](#ke-15) | Guard tests mount existence, not mount identity | Resolved 2026-07-14 |
| [KE-16](#ke-16) | Apache serves a certificate already renewed on disk | Resolved 2026-07-10 |
| [KE-17](#ke-17) | VM100 silent guest hard-freeze | Open - cause unknown, one occurrence |
| [KE-18](#ke-18) | Services start before Tailscale is ready | Mitigated - every known instance gated, cold boot 2026-10-13 |
| [KE-19](#ke-19) | A file that changes during a sync poisons the array signal | Resolved 2026-08-15; recurrence fixed 2026-10-08 |
| [KE-20](#ke-20) | VM100 froze during a live CIFS unmount | Open - cause unknown; vm100 snapshottable since 2026-10-10 |
| [KE-21](#ke-21) | A kernel oops cascade wedged the hypervisor | Resolved 2026-09-12; memory test pending |
| [KE-22](#ke-22) | A retired deployment stayed on disk and broke the backup | Resolved 2026-09-01 |
| [KE-23](#ke-23) | A role gained a task and seven nodes never received it | Resolved 2026-09-16 |
| [KE-24](#ke-24) | sshd's reload is a re-exec and cannot rebind | Resolved 2026-09-04 |
| [KE-25](#ke-25) | A UID map that exists only in the container's description | Resolved 2026-09-15; second instance 2026-10-08 |
| [KE-26](#ke-26) | The wake alarm was programmed for the right time on the wrong day | Resolved 2026-09-25 |
| [KE-27](#ke-27) | A container whose start fails at boot stays down until someone starts it | Mitigated 2026-10-03 - retry not yet exercised by a real failure |
| [KE-28](#ke-28) | Jellyfin streams stalled inside the `tailscale serve` TCP forwarder | Resolved 2026-10-07 |

---

<a id="ke-1"></a>

## KE-1: SQLite on CIFS - "database is locked"

- **Status:** Resolved - no database files on CIFS (architectural rule)
- **Affects:** OpenWebUI (lxc230)

**Symptom.** `peewee.OperationalError: database is locked`.

**Cause.** SQLite relies on POSIX file locking, which CIFS/SMB does not implement reliably.
OpenWebUI's default SQLite database lived on a CIFS mount.

**Fix.** OpenWebUI uses PostgreSQL on local block storage in lxc260. Platform rule: no database
files (SQLite or PostgreSQL data directories) on CIFS/SMB or automount-backed shares.

**Verification.** OpenWebUI runs against lxc260
([PostgreSQL platform service](../services/postgresql-platform.md),
[OpenWebUI](../services/openwebui.md)).

---

<a id="ke-2"></a>

## KE-2: Grafana datasource unreachable after host networking switch

- **Status:** Resolved
- **Affects:** Grafana (lxc200)

**Symptom.** Dashboards empty; the provisioned Prometheus datasource returned connection errors.

**Cause.** The monitoring stack moved to `network_mode: host`. Docker's container-name DNS exists
only on bridge networks, so `http://prometheus:9090` no longer resolved.

**Fix.** Datasource URL changed to `http://127.0.0.1:9090`. In host-networked stacks every
inter-service reference uses `127.0.0.1` or the node's Tailscale IP, never a container name
([design decisions](../decisions/design-decisions.md)).

**Verification.** Datasource health check in Grafana returns OK.

---

<a id="ke-3"></a>

## KE-3: Failed run-rpc_pipefs.mount in LXC210

- **Status:** Resolved 2026-09-11
- **Affects:** Nextcloud node (lxc210)

**Symptom.** `systemctl --failed` lists `run-rpc_pipefs.mount`.

**Cause.** The unit is generated by `nfs-common`. The unprivileged container lacks the
capability to mount the RPC pipe filesystem, and Nextcloud uses CIFS, not NFS. The same package
pulled in `rpcbind`, listening on `0.0.0.0:111`.

**Fix.** `nfs-common` and `rpcbind` removed through `systemd_hygiene_absent_packages` in
`ansible/inventory/host_vars/lxc210.yml`. The `systemd_hygiene` role simulates the removal with
`apt-get -s` and refuses if apt would remove anything else. No mask remains.

**Verification.** Verified 2026-09-12: both packages absent on lxc210, port 111 closed, no failed
unit ([ansible.md](ansible.md#roles)).

---

<a id="ke-4"></a>

## KE-4: Docker creates directories for missing bind-mount files

- **Status:** Open - Docker design behaviour, manual recovery
- **Affects:** any Compose stack that bind-mounts a gitignored config file (seen: Prometheus on
  lxc200)

**Symptom.** Container fails to start with `error mounting "..." to rootfs: not a directory`; the
exit code can mislead (for example 127).

**Cause.** When a bind-mount source does not exist, Docker creates an empty directory at that
path. A container expecting a file then fails on the type mismatch. Typical triggers: the config
was never created from its `.example`, was removed by `git clean -x`, or was deleted by hand.

**Fix.** Per occurrence:

1. `rmdir <path>`
2. Recreate the file from its `.example` template.
3. Restart the container.

Files affected today: `docker/monitoring/prometheus/prometheus.yml` and
`docker/monitoring/grafana.env`. `scripts/validate-repo.sh` checks the repository, not whether
runtime files exist on a node; after a clone, copy each `.example` before starting containers.

**Verification.** `docker compose ps` shows the container running; `stat -c %F <path>` reports
`regular file`. See [monitoring.md](./monitoring.md).

---

<a id="ke-5"></a>

## KE-5: Vaultwarden SQLite on CIFS - acknowledged technical debt

- **Status:** Resolved 2026-09-01 by decommissioning
- **Affects:** Vaultwarden (withdrawn)

**Symptom.** Vaultwarden kept its SQLite database on a CIFS mount, violating the rule from
[KE-1](#ke-1).

**Cause.** Deployed with the default SQLite backend before KE-1 set the rule.

**Fix.** The service was withdrawn instead of migrated
([decommission decision](../decisions/vaultwarden-decommission.md)). The decision record keeps the
PostgreSQL route for a reinstatement.

**Verification.** Before shutdown, `PRAGMA wal_checkpoint(TRUNCATE)` returned zero frames and
`PRAGMA integrity_check` returned `ok`: the surviving `-wal` file held no data. The node and its
share data no longer exist; see the decision record for the cold archive.

---

<a id="ke-6"></a>

## KE-6: Tailscale userspace-networking prevents node_exporter from binding to Tailscale IP

- **Status:** Resolved 2026-07-28; stray unit removed 2026-09-01
- **Affects:** any node running `tailscaled` in userspace mode (seen on lxc220 and on a container
  since decommissioned)

**Symptom.** Two forms:

- Bind fails: `listen tcp <tailscale-ip-...>:9100: bind: cannot assign requested address`, and
  `ip addr show tailscale0` reports no device.
- Bind succeeds, scrape fails (lxc220): `node_exporter` active and listening on the Tailscale IP,
  `tailscale0` present, Prometheus reports `connection refused`. `tailscale serve` traffic still
  works, so blackbox probes stay green.

**Cause.** `tailscaled` in userspace-networking mode terminates connections in its own netstack
and never hands them to kernel sockets. On the first node the mode came from
`FLAGS="--tun=userspace-networking"` in `/etc/default/tailscaled`. On lxc220 it came from a second,
hand-written `tailscaled-userspace.service` enabled beside the packaged unit, so every boot started
two daemons on the same state and socket paths. Config files showed nothing; only the process
list did.

**Fix.** Remove the flag, or `systemctl disable --now tailscaled-userspace.service`, then
`systemctl restart tailscaled.service`. The lxc220 unit file was deleted on 2026-09-01
([KE-22](#ke-22)).

**Verification.** Check the running state, not the bind:

```
ps -o pid,args -C tailscaled                  # exactly one process
systemctl list-unit-files | grep -i tailscale # exactly one enabled unit
pct exec 200 -- curl -s -o /dev/null -w '%{http_code}\n' http://<tailscale-ip-lxc220>:9100/metrics
```

Verified 2026-08-13 after a host power cycle: one `tailscaled` on lxc220, scrape `200`. The same
`EADDRNOTAVAIL` message also comes from the boot race in [KE-18](#ke-18); a restart fixes that one
and not this one.

---

<a id="ke-7"></a>

## KE-7: Package corruption when LVM thin-pool overflows during apt upgrade

- **Status:** Resolved 2026-04-26
- **Affects:** every guest on the `local-lvm` thin pool (seen 2026-04-25 on lxc230 and lxc260,
  2026-04-26 on lxc220)

**Symptom.**

- `No space left on device` during `apt dist-upgrade` while `df -h /` shows free space
- `dpkg-deb: error: not a Debian format archive` on cached `.deb` files
- `file /usr/sbin/tailscaled` (or `/bin/bash`, `/usr/bin/dockerd`, `/usr/bin/runc`) returns `data`;
  SSH returns `Exec format error`, Docker fails with `status=203/EXEC`
- VMs enter `status: io-error`; after a Docker reinstall, `container with given ID already exists`

**Cause.** The thin pool reached 100 % during a parallel `apt dist-upgrade` on all nodes. Writes
failed at the block layer and truncated binaries mid-write, while guests still saw virtual free
space. No periodic `fstrim` returned deleted blocks to the pool. Binaries already in memory kept
running, so corruption surfaced only at the next start of each service.

**Fix.**

1. `apt-get clean` on all nodes; `fstrim` every LXC from the host through `nsenter`.
2. `qm resume <vmid>` for suspended VMs.
3. `dpkg --configure -a` and `apt --fix-broken install -y`.
4. List corrupt files: `dpkg --verify 2>&1 | grep -v ' c /'` (lines with `c` are edited conffiles).
5. `apt-get install --reinstall <packages>` in one pass, then restart the services.
6. For stale containerd state: `docker rm -f <container>`, then `docker compose up -d`.

Prevention: upgrades run `serial: 1`; LXC `fstrim` runs on a timer
(`snippets/scripts/lxc-fstrim.sh`, deployed by `proxmox_host_units`); thin-pool usage is
exported and alerted (`LvmThinPool*` rules).

**Verification.** `dpkg --verify 2>&1 | grep -v ' c /'` prints nothing on every node. Procedure:
[LVM thin-pool full runbook](../../runbooks/platform/lvm-thin-pool-full.md).

---

<a id="ke-8"></a>

## KE-8: Media services hang while the node stays healthy (observability blind spot)

- **Status:** Mitigated 2026-06-08 - service probes alert; cause not found
- **Affects:** Jellyfin and Audiobookshelf (vm100)

**Symptom.** 2026-06-06, about 12:00-14:36 UTC: neither web UI answered. Jellyfin logged only
sporadic `WS request -> closed`; Audiobookshelf was silent after `Listening on port :80`. Processes
alive, not serving. A vm100 restart restored both. No alert fired.

**Cause.** Not determined; the application logs for the window were not retained. Excluded by
measurement:

- vm102 up throughout (`wtmp`); pool never at 0 bytes free.
- `up{job="node-vm100-gpu"}` was 1 for 300 of 300 samples; no network loss.
- No `CIFS VFS: server not responding` or hung-task message in `/var/log/kern.log`.
- `node_procs_blocked` max 1, `node_load5` max 0.27, at least 14 GiB RAM free.

Leading hypothesis: a stalled SMB read to vm102 (an interruptible wait, invisible in
`procs_blocked`) or a container-internal deadlock.

**Fix.** Recovery: `docker restart jellyfin audiobookshelf`, or restart vm100. Detection:
`blackbox_exporter` on lxc200 probes every service endpoint and `ServiceDown` alerts
([monitoring.md](./monitoring.md)). Journald persistence is pinned by the `journald` role
(`Storage=persistent`).

**Verification.** `ServiceDown` has since fired for real outages ([KE-16](#ke-16),
[KE-17](#ke-17)).

---

<a id="ke-9"></a>

## KE-9: PostgreSQL binds only loopback after boot (Tailscale-IP startup race)

- **Status:** Resolved 2026-06-09
- **Affects:** PostgreSQL on lxc260 and its clients (OpenWebUI, Paperless-ngx)

**Symptom.** Found 2026-06-08 by the first blackbox run: `tailscale serve` returned 502 for
Paperless and OpenWebUI. OpenWebUI crash-looped with `UnboundLocalError: cannot access local
variable 'db'` in `handle_peewee_migration`. `pg_up` stayed 1, because `postgres_exporter`
connects over loopback.

**Cause.** `listen_addresses` is `127.0.0.1, <tailscale-ip-lxc260>`. PostgreSQL binds only
addresses that exist at start; it started before the Tailscale IP was assigned, bound loopback
alone and never retried the other address. Signature:

```bash
ss -ltn | grep ':5432'                                # actual binds
sudo -u postgres psql -tAc 'SHOW listen_addresses;'   # configured binds
```

**Fix.** Recovery: `systemctl restart postgresql` once the Tailscale IP exists. Durable: role
`postgresql_boot_order` adds a drop-in to `postgresql@15-main.service` with `After=`/`Wants=`
`tailscaled.service` and `ExecStartPre=/usr/local/bin/wait-for-tailscale-ip.sh`.
`listen_addresses='*'` was rejected because it binds the LAN interface
([ADR](../decisions/postgresql-tailscale-boot-ordering.md)).

A separate fault surfaced in the same window: Paperless crash-looped (`RestartCount` 2443) on
`Error 111 connecting to localhost:6379`. The `paperless_env` default was
`redis://localhost:6379`; on a Compose bridge network Redis is reachable by service name. Default
is `redis://redis:6379`.

**Verification.** Verified 2026-06-09 by reboot of lxc260: gate logged `tailscale IP present after
2s`, PostgreSQL bound `<tailscale-ip-lxc260>:5432`; Paperless `healthy`, backend HTTP 302. See
[KE-18](#ke-18) for the general pattern.

---

<a id="ke-10"></a>

## KE-10: Jellyfin loses CUDA access intermittently - container restart required

- **Status:** Mitigated - fault active, stream-aware watchdog restart
- **Affects:** Jellyfin (vm100)

**Symptom.** Hardware transcoding stops; playback that needs a transcode stalls or fails. The
container stays up. `nvidia-smi` inside the container fails. A container restart restores it.

**Cause.** Not determined. `pid: "host"` is set in `docker/jellyfin/docker-compose.yml` for
NVIDIA Container Toolkit access; the runtime loss suggests the NVML connection to the host driver
goes stale. Trigger unknown.

**Fix.** Workaround only. Role `jellyfin_watchdog` runs
`snippets/scripts/jellyfin-cuda-watchdog.sh` every minute. On CUDA loss it queries Jellyfin's
`/Sessions` API: it restarts the container when nothing plays or a stream transcodes video, and
holds while only direct streams play, since a restart ends every running stream.
`JellyfinCudaLost` fires after ten minutes without CUDA, so a held restart is visible
([jellyfin.md](../services/jellyfin.md)).

**Verification.** Fault frequency: 30 watchdog restarts between 2026-05-29 and 2026-10-08, the
latest 2026-10-08 11:29:

```
journalctl -t jellyfin-cuda-watchdog | grep "CUDA access lost"
```

---

<a id="ke-11"></a>

## KE-11: Grafana admin password not updated by environment variable after first start

- **Status:** Open - Grafana design behaviour, non-blocking
- **Affects:** Grafana (lxc200)

**Symptom.** After changing `GF_SECURITY_ADMIN_PASSWORD` in `.env` and restarting, the new
password is rejected; the old one still works.

**Cause.** Grafana writes the admin password to `grafana.db` on first start and ignores the
variable afterwards.

**Fix.**

```bash
docker exec -it grafana grafana-cli admin reset-admin-password <new-password>
```

**Verification.** Login with the new password succeeds. See [lxc200](../nodes/lxc200.md).

---

<a id="ke-12"></a>

## KE-12: pveproxy fails to start after boot (Tailscale-IP bind race)

- **Status:** Resolved 2026-06-25; gate owned by `tailscale_boot_gate` since 2026-09-12
- **Affects:** Proxmox host, `pveproxy` (web UI and API on `:8006`)

**Symptom.** After a host boot SSH works, `:8006` does not answer, `systemctl is-active pveproxy`
is `failed`. The journal shows, five times within seconds of boot:

```
start failed - unable to create socket - Cannot assign requested address
pveproxy.service: Start request repeated too quickly.
```

**Cause.** `/etc/default/pveproxy` sets `LISTEN_IP=<tailscale-ip-proxmox-host>` (web UI on the
tailnet only). `pveproxy` started before `tailscaled` assigned that IP, exited on `EADDRNOTAVAIL`,
and systemd's start limit stopped it after five fast retries. An instance of [KE-18](#ke-18).

**Fix.** Recovery: `systemctl reset-failed pveproxy && systemctl restart pveproxy`. Durable: the
`tailscale_boot_gate` role (`pveproxy.service` in `ansible/inventory/group_vars/proxmox.yml`)
writes `10-wait-tailscale.conf` with `ExecStartPre=/usr/local/bin/wait-for-tailscale-ip.sh`, and
removes the hand-written `wait-tailscale.conf` that held the race shut from 2026-06-25
([ADR](../decisions/pveproxy-tailscale-boot-ordering.md),
[runbook](../../runbooks/platform/pveproxy-tailscale-boot-race.md)).

**Verification.** Cold boot 2026-08-13 with the hand-written gate: start requested 10:52:26, main
process 10:52:30, `NRestarts=0`. Verified 2026-09-12: `pveproxy.service.d/` holds only
`10-wait-tailscale.conf`, the gate's `ExecStartPre` exited 0, re-check `changed=0`.

---

<a id="ke-13"></a>

## KE-13: aux-disk physical disk failure (medium errors)

- **Status:** Open - degrading, in service, replacement planned
- **Affects:** Proxmox host aux-disk (`/mnt/aux-disk`), which holds the Docker data-roots of lxc200,
  lxc211, lxc220 and lxc230, the PostgreSQL data directory of lxc260, vm100's `scsi1` (qcow2), and
  the guest backup target (`/mnt/vzdump`)

**Symptom.** 2026-06-25: the disk would not mount at boot; the host dropped into emergency mode,
and later the five containers above refused to start because their bind-mount sources were missing
([incident](./incidents/2026-06-25-aux-disk-failure-and-recovery.md)).

**Cause.** Unrecoverable medium errors on a consumer drive with about 6.5 years power-on: kernel
`critical medium error ... Unrecovered read error`, and SMART counters below. A contributing risk
was found on 2026-07-09: the same partition was mounted on the host and passed through to vm102 as
`scsi8` (vm102 did not mount it).

SMART, identified by serial (`by-id`), never by kernel letter ([KE-14](#ke-14)):

| Attribute | 2026-06-25 | 2026-07-09 to 2026-09-15 | 2026-10-08 | 2026-10-13 |
|---|---|---|---|---|
| `Current_Pending_Sector` | 7688 | 7680 | 8168 | 8784 |
| `Offline_Uncorrectable` | 7688 | 7680 | 8168 | 8784 |
| `Reallocated_Sector_Ct` | 0 | 0 | 0 | 0 |
| `Reported_Uncorrect` | 18 | 21 | 21 | 21 |

The first step happened at the boot of 2026-09-20 (Prometheus history: 7848 at 20:17, 8168 at
20:30), the second at the boot of 2026-10-13 (8344 at 12:25, 8784 at 12:38). `Reported_Uncorrect`
has not moved since July, so no read by a consumer has failed; the new sectors point at the drive's
own offline scan. `smartctl -H` reports `PASSED`, because `Current_Pending_Sector` normalises to
`054` against threshold `000`; do not read it as a health check.

**Fix.** Mitigations in place:

- `nofail` on the fstab entry keeps the host out of emergency mode.
- All data rescued read-only before any repair
  ([rescue runbook](../../runbooks/storage/aux-disk-failure-rescue.md)).
- 2026-07-09: passthrough removed (`qm set 102 --delete scsi8`); vm102's commented fstab line
  replaced by a warning.
- 2026-08-17: `appdata_aux-disk` in `/etc/pve/storage.cfg` carries `is_mountpoint 1`, so Proxmox
  does not write into the empty mountpoint on `pve-root` if the disk fails to mount
  ([KE-7](#ke-7) failure class).
- 2026-09-15: `smart_metrics` replaced the hand-written collector; `SmartAttributeDegrading` keys
  counters by serial since 2026-10-10.

The disk returned to service on 2026-07-09 because no other target has room. The
`docker-compose-update` hold was lifted 2026-09-05. Treat everything on the disk as unbacked off
site. Replacement: [remediation plan](remediation-plan.md#aux-disk-replacement-and-disposal).

**Verification.** `SmartAttributeDegrading` went pending at 12:26 and fired at 12:40 on
2026-10-13; replayed over the 30 days before 2026-10-10 it fires only for the 2026-09-20 step. A
guest backup wrote about 13 GB to the disk on 2026-10-13 with all four counters unchanged.

---

<a id="ke-14"></a>

## KE-14: Read commands to the boot SSD time out under load (SAS HBA transport, not media)

- **Status:** Open - drive replacement in the second half of October 2026
- **Affects:** Proxmox host boot SSD behind the LSI SAS2008 HBA (`scsi 9:0:0:0`, `phy(3)`,
  `mpt2sas`, `/dev/disk/by-id/<boot-ssd-by-id>`); it holds `/boot/efi`, `pve-root` and the
  `pve-data` thin pool with every guest root disk

**Symptom.** Bursts of failed read commands, each a roughly 30 s stall:

```
sd 9:0:0:0: [<boot-ssd>] tag#628 FAILED Result: hostbyte=DID_SOFT_ERROR driverbyte=DRIVER_OK cmd_age=19s
I/O error, dev <boot-ssd>, sector 125570656 op 0x0:(READ) flags 0x80700 phys_seg 3 prio class 2
```

Some commands report `DID_TIME_OUT` instead; count both host bytes. Kernel letters (`sda`, `sdc`)
change between boots; identify the disk by `9:0:0:0` or `by-id`.

Failed commands at `9:0:0:0` per month, every boot in the persistent journal (measured 2026-10-12):

| Month | Boots | Boots with failures | Failed commands |
|---|---|---|---|
| 2026-06 | 11 | 4 | 38 |
| 2026-07 | 24 | 14 | 272 |
| 2026-08 | 25 | 10 | 209 |
| 2026-09 | 28 | 10 | 211 |
| 2026-10, to the 12th | 12 | 9 | 333 |

Per boot on the 7.0 kernel, from 2026-10-12 13:50 to 2026-10-17 10:51 (measured 2026-10-17): 0, 11,
0, 0, 0 and 2. The two on 2026-10-17 fell at 11:06, inside the guest backup. The last three boots on
6.17 logged 60, 39 and 16. Load differs between these days, so the drop is not attributed to the
kernel.

Bursts follow I/O-heavy steps (image pulls, fleet upgrades, boot) and since 2026-10-05 occur on
every boot and outside boot, often in the first minute of an hour. Every `I/O error` line is a
`READ`; no `EXT4-fs error`, device-mapper or `Buffer I/O error` line has been logged.

**Cause.** Not confirmed. Excluded:

- Media: `DID_SOFT_ERROR`/`DID_TIME_OUT` are adapter-side timeouts with no sense data; a bad
  sector reports `DRIVER_SENSE` with `Medium Error` within milliseconds. SMART error log: `No
  Errors Logged`; reallocation and program/erase fail counters zero.
- HBA firmware: `20.00.07.00`, outside the faulty P20 phases 20.00.00.00 to 20.00.04.00.
- SATA controller: the SSD is on the SAS2008 (`lsblk -dno NAME,TRAN` reports `sas`).

Candidates: 12 V rail sag (`sensors` reads `+12V 10.03 V`, an unverified board sensor), or HBA
heat (passively cooled). The drive is worn but not failing: 58,540 power-on hours,
`Wear_Leveling_Count` normalised 047, `Used_Rsvd_Blk_Cnt_Tot` `WHEN_FAILED=In_the_past` with raw 0.

A second port shows transport faults. On 2026-10-15 at boot, one `DID_SOFT_ERROR` hit `9:0:2:0`
(`phy(1)`), an 8 TB data disk identified by WWN. Its UDMA CRC count stood at 368 until 2026-10-13
and at 393 on 2026-10-17. Faults on two ports fit the HBA, its cabling or its power better than the
SSD alone.

**Fix.** The drive is replaced in the second half of October 2026
([boot SSD replacement](../../runbooks/platform/boot-ssd-replacement.md), [remediation plan](remediation-plan.md#boot-ssd-replacement)); its 110 GiB volume
group is also too small. The 6.17.13 kernel pin was released 2026-10-12 so the kernel and the
drive do not change together; the baseline is the old drive on the 7.0 kernel from 2026-10-13.

**Verification.** Failed commands per boot before and after the swap. On the same port and cable
this separates drive from transport; on an onboard SATA port it separates the HBA path from power.
Since the boot of 2026-10-17 10:51 a sixth 7200 rpm data disk runs on the HBA (`9:0:5:0`) and adds
12 V load on an unrecorded rail; counts after the swap are compared against this configuration.
If errors persist, run the
[power-path check](../../runbooks/platform/ke14-power-path-check.md) and record the result here.

---

<a id="ke-15"></a>

## KE-15: Guard tests mount existence, not mount identity - calibre-import dead for a month

- **Status:** Resolved 2026-07-14
- **Affects:** lxc220 `calibre-import.service`, role `calibre_importer`,
  `snippets/scripts/calibre-import.sh`; host CIFS mount `/mnt/smb/books-rw`

**Symptom.** From 2026-06-08 `calibre-import.service` failed every 2 minutes; no ebook was
imported and nothing alerted:

```
calibre-import.sh[3904]: mkdir: cannot create directory '/books-rw/_import': Permission denied
```

**Cause.** A chain:

1. On the host, `/mnt/smb/books-rw` (`//vm102/Books`) was not mounted. Its fstab line lacked
   `x-systemd.automount`, so systemd tried once at boot, before `pve-guests` had started vm102
   (`mount error(113)`), and never retried.
2. The `mp2` bind exposed the empty directory beneath it on `pve-root`, owned by host root, which
   the unprivileged container sees as `65534`.
3. `mkdir` failed with `EACCES`; `set -euo pipefail` exited 1.

Both guards used `mountpoint -q /books-rw`, which succeeds because the bind is itself a mount. The
Ansible guard also lacked `check_mode: false`, so `--check` skipped it. A failed unit raised no
alert at the time.

**Fix.**

- Guards test identity: `findmnt -no FSTYPE /books-rw` must return `cifs`, and `metadata.db` must
  exist. The script exits 1, not 0, when the library is absent; the role probe runs in check mode
  and deploys the script before asserting the mount.
- Host fstab: every `/mnt/smb/*` entry carries `x-systemd.automount`, so the mount happens on first
  access, after vm102 is up.
- The old `trigger-smb.mounts.service`, which ran before vm102 started and swallowed errors, is
  replaced by `smb-mounts-check.service` (`After=pve-guests.service`, fails if any `/mnt/smb/*` is
  not `cifs`), deployed by `proxmox_host_units`
  ([runbook](../../runbooks/storage/smb-autofs-trigger.md)).
- `node_exporter --collector.systemd` with `.mount` units in scope, plus `SystemdUnitFailed`.

**Verification.** Verified 2026-08-13 after a host power cycle: all seven `/mnt/smb/*` resolve to
`cifs`, `grep '/mnt/smb/' /etc/fstab | grep -v x-systemd.automount` prints nothing,
`smb-mounts-check` and `calibre-import` exit 0, and `findmnt -no FSTYPE /books-rw` in lxc220
returns `cifs`.

---

<a id="ke-16"></a>

## KE-16: Apache serves an expired certificate that was already renewed on disk

- **Status:** Resolved 2026-07-10
- **Affects:** Nextcloud on lxc210 (Apache with the Tailscale-issued certificate)

**Symptom.** 2026-07-10: `ServiceDown` fired for `nextcloud`. `curl` returned `http=000`,
`ssl_verify_result=10` (`X509_V_ERR_CERT_HAS_EXPIRED`); with `-k` it answered `302`. Apache,
MariaDB, Redis and PHP-FPM were all `active`.

**Cause.** The served certificate had `notAfter=Jul 10 09:53:15 2026 GMT`. The file in
`/var/lib/tailscale/certs/` had been renewed by `tailscaled` fifteen minutes before expiry. Apache
reads `SSLCertificateFile` at start and kept serving the old certificate from memory. lxc210 is
the only node whose service reads the file directly; the others terminate TLS in
`tailscale serve`, which fetches the certificate per connection.

**Fix.** Immediate: `tailscale cert ... --min-validity 720h <fqdn>` (reported unchanged), then
`systemctl reload apache2`. Durable: role `tailscale_cert` on inventory group
`tailscale_cert_ondisk` (lxc210 only) deploys `snippets/scripts/tailscale-cert-refresh.sh` with a
daily `Persistent=true` timer. The script hashes the certificate, runs `tailscale cert
--min-validity 720h`, and reloads Apache only if the hash changed. Its boot-time failure mode is
covered in [KE-18](#ke-18).

**Verification.** Probe returned `http=302`, `ssl_verify=0` after the reload. A manual run logs
`certificate unchanged (valid for at least 720h) - no reload needed` and exits 0. The reload branch
has not been exercised against a real renewal.

Apache still listens on `*:80` and `*:443`, a separate deferred binding-rule exception (recorded in
`listener_metrics_allowed` for lxc210, see [lxc210](../nodes/lxc210.md)).

---

<a id="ke-17"></a>

## KE-17: VM100 silent guest hard-freeze - no logged root cause, recovered by hard power-cycle

- **Status:** Open - cause unknown, one occurrence
- **Affects:** vm100 guest OS (GPU passthrough node), not the hypervisor

**Symptom.** 2026-07-11: vm100 unreachable over SSH and Tailscale; `ssh` hung at TCP connect.
`tailscale status`: `offline, last seen 8h ago`. `qm status 100` reported `running`. QEMU guest
agent ping and ACPI powerdown both timed out; `qm terminal 100` was blank.

**Cause.** Not determined. Evidence:

- Guest journal (`journalctl -b -1`) ends at `01:41:13 UTC` with no shutdown sequence. A grep for
  `oom|hung task|soft lockup|BUG:|call trace|watchdog` found only the boot-time
  `NMI watchdog: Enabled`.
- Host journal 03:30-03:50 CEST: no `kvm`, `vfio`, `nvidia`, `oom` or VMID-100 message, and the SMART
  collector completed at 03:41. Not [KE-14](#ke-14).
- Guest clock is UTC, host clock CEST: the freeze was 03:41 CEST, inside a host boot that had been
  started by hand that night.

A link to the NVIDIA path ([KE-10](#ke-10)) is plausible and unproven.

**Fix.** Recovery: `qm stop 100` then `qm start 100`; node back within about 2 minutes. Not
applied: a QEMU watchdog device (`i6300esb`) with `softdog` in the guest for automatic reset, and
`kdump`/`pstore` for a trace that survives a freeze. The in-guest NMI watchdog is not a substitute;
it depends on PMU counters that KVM virtualizes unreliably. vm100's kernel log streams to the host
by netconsole ([KE-20](#ke-20)).

**Verification.** Detection worked: `NodeDown` and `ServiceDown` fired at 03:45 CEST, about 4
minutes after the freeze; the outage lasted about 8 hours because no one responded overnight. See
the [incident record](incidents/2026-07-11-vm100-silent-freeze.md).

---

<a id="ke-18"></a>

## KE-18: Services start before Tailscale is ready (ordering is not readiness)

- **Status:** Mitigated - every known instance gated, cold boot 2026-10-13
- **Affects:** any unit that binds a Tailscale address or queries `tailscaled` at boot

**Symptom.** In the boot window only; a manual start later succeeds:

```
bind: cannot assign requested address        # bind-time variant (EADDRNOTAVAIL)
could not determine the node's MagicDNS name # query-time variant
```

**Cause.** `After=tailscaled.service` orders a unit after `tailscaled` has started; a
`Type=simple` service counts as started when its process exists, before it joins the tailnet and
gets an address. With `Restart=on-failure` and the default `RestartSec=100ms`, five attempts run
inside about 24 ms and the start limit stops the unit for good. The host powers down nightly, so
every day is a cold boot, and `Persistent=true` timers catch up on missed runs inside the boot window.

Retry loops can hide the fault: on 2026-08-20 all nine guest `node_exporter` units showed
`NRestarts=1`, and `SystemdUnitFailed` (`for: 15m`) never saw the 15-second failure.

**Fix.** Bind-time: `ExecStartPre=/usr/local/bin/wait-for-tailscale-ip.sh <timeout>` plus a
`RestartSec` well above the default, through role `tailscale_boot_gate` or the owning role's unit
template. Query-time: poll for the value inside the script. Do not write the poll inline in a unit
file: systemd expands `$` in `ExecStartPre=`, and an inline loop can silently run zero times.

| Node / unit | Variant | Fix |
|---|---|---|
| lxc260 `postgresql@15-main` | bind | `postgresql_boot_order` ([KE-9](#ke-9)) |
| host `pveproxy` | bind | `tailscale_boot_gate` ([KE-12](#ke-12)) |
| host and nine guests `node_exporter` | bind | gate in the `node_exporter` unit template |
| lxc210 `tailscale-cert-refresh` | query | FQDN poll, up to 90 s, in `snippets/scripts/tailscale-cert-refresh.sh` |
| sshd on every guest | bind | `tailscale_boot_gate` with `ssh_hardening_listen_address` ([decision](../decisions/sshd-listen-address.md)) |
| lxc200 `blackbox-exporter` | resolver | MagicDNS resolver named in the compose file |
| vm100 `docker.service` (Jellyfin) | bind | `tailscale_boot_gate`, `docker_boot_retry` behind it ([KE-28](#ke-28)) |

For sshd, Debian's `ssh.service` sets `RestartPreventExitStatus=255` and sshd exits 255 on a
failed bind; `tailscale_boot_gate_clear_restart_prevent` clears it so the retry backstop works.

**Verification.** Fleet cold boot 2026-08-21: all nine guest `node_exporter` units `NRestarts=0`,
each `ActiveEnterTimestamp` after the node's `uptime -s`. Gate waits (`present after Ns`) ranged
from 0 s (vm100) to 12 s (lxc210, lxc220). Cold boot 2026-10-10: vm100 `docker` active 77 s after
boot, `NRestarts=0`. Cold boot 2026-10-13 confirmed vm102's sshd pin and vm100's `docker.service`
gate. Read `NRestarts` together with the boot timestamp; a manual restart also resets it.

---

<a id="ke-19"></a>

## KE-19: A file that changes during a sync poisons the health signal of the whole array

- **Status:** Resolved 2026-08-15; recurrence fixed 2026-10-08
- **Affects:** SnapRAID on vm102; `SnapRAIDSyncStale` and `SystemdUnitFailed` for
  `snapraid-maintenance@sync.service`

**Symptom.** The sync completes, saves its content files, then exits 1:

```
Unexpected size change at file '/mnt/disk03/Nextcloud/nextcloud.log' from 3541768 to 3554509.
WARNING! You cannot modify files during a sync.
      14 file errors
       0 io errors
       0 data errors
```

`0 io errors` and `0 data errors` rule out media faults and corruption.

**Cause.** SnapRAID cannot protect a file that changes while it is read; it fails that file and
exits non-zero. The 23:00 slot was chosen for quiet, but the host powers down nightly, so
`Persistent=true` usually runs the sync at the next boot, while services write. One non-zero exit
stops `snapraid-maintenance.sh` (`set -e`) before it writes the success metric, so the whole array
reads stale. 2026-10-08: same symptom from a PostgreSQL dump renaming its `*.partial` mid-sync
(`Missing file '.../pg_dumpall_20261008_102227.sql.gz.partial'`).

**Fix.** The `snapraid_maintenance` role owns the exclude rules in a marked `blockinfile` block of
`/etc/snapraid.conf`:

```
exclude /Nextcloud/nextcloud.log
exclude /Nextcloud/nextcloud.log.*
exclude *.sqlite3-shm
exclude *.sqlite3-wal
exclude *.db-shm
exclude *.db-wal
exclude /Nextcloud/appdata_*/richdocuments/remoteData/
exclude *.partial
```

Exclude by what changes, not by suffix: `exclude *.log` also dropped static files from the
archive and was narrowed. SQLite side files are excluded because parity taken at a different moment
than the main database is inconsistent. The disk and parity layout above the block stays
hand-written, because it carries real device labels.

**Verification.** 2026-08-15, in order (sync has no rollback,
[snapraid-sync runbook](../../runbooks/storage/snapraid-sync.md)): `snapraid diff` before and after
the excludes, every change explained; `systemctl start snapraid-maintenance@sync.service`
`Result=success`; `snapraid diff` reports no differences; both alerts cleared. Live block marker on
vm102: `# BEGIN ANSIBLE MANAGED - exclude rules (KE-19)`.

---

<a id="ke-20"></a>

## KE-20: VM100 froze during a live CIFS unmount, no evidence recorded

- **Status:** Open - cause unknown; vm100 snapshottable since 2026-10-10
- **Affects:** vm100

**Symptom.** 2026-08-16 19:20 UTC: `systemctl stop` on the two media `.mount` units wedged the
guest. SSH over Tailscale and ICMP over the LAN stopped; QMP answered, the guest agent did not, ACPI
shutdown timed out. `qm stop` and `qm start` recovered it after about 25 minutes of media outage.

**Cause.** Unknown. The guest journal ends at 19:20:39 inside the SSH connection that ran the
command; the last kernel line, 19:20:17, is the veth teardown from the preceding `docker stop`. No
`CIFS VFS` error, no `task blocked for more than 120 seconds`, no call trace, and not even
systemd's `Unmounting ...`. A userspace deadlock would have kept logging; this points below the
logging layer. The client recorded `Connection reset by peer` (exit 255) without a timestamp, so
it may come from the restarted guest. The host logged no kernel message in that window, so the
[KE-13](#ke-13) disk is not implicated. Weak signal: six `perf: interrupt took too long` lines
between 17:01 and 17:15.

**Fix.** The share change was completed without unmounting on a running system: new mount units on
new paths, `.env` repointed, containers recreated, old automounts disabled and retired by the next
power-off. Evidence for a repeat: the `netconsole` role on vm100 streams the guest kernel log to
the host receiver (`ansible/roles/proxmox_host_units/templates/netconsole-receiver.service.j2`)
with `console_loglevel` 7, so `INFO: task blocked` reaches it. vm100's data disk is qcow2 since
2026-10-10, so a repeat attempt can be preceded by a snapshot.

**Verification.** Not reproduced. Do not unmount CIFS live on vm100 without a snapshot and a
timestamped client transcript.

---

<a id="ke-21"></a>

## KE-21: A kernel oops cascade wedged the hypervisor, and nothing could report it

- **Status:** Resolved 2026-09-12; memory test pending
- **Affects:** Proxmox host

**Symptom.** 2026-08-20 from about 12:39: new SSH connections got no banner; the web UI refused
login with `401 invalid PVE ticket`; every guest showed `unknown`; shutdown through the API had no
effect. Guests kept running. Recovery needed a hard reset after about 2.5 hours. `node_exporter`
still answered: load 22 with 1-3 running processes, no blocked processes, no I/O pressure, and:

```
node_filesystem_device_error{device="lxcfs",mountpoint="/var/lib/lxcfs",device_error="mountpoint timeout"} 1
```

**Cause.** Persistent host journal, previous boot. 12:38:25, first oops (taint `P O`, no `D` yet):

```
BUG: unable to handle page fault for address: ffff8adf00000051
CPU: 3  PID: 140185  Comm: lxc-info   Tainted: P O
RIP: anon_vma_interval_tree_insert+0x4b/0xe0
```

Then six general protection faults in `kmem_cache_alloc_noprof+0x203/0x3e0`, each with the same
non-canonical pointer `0xcfb9e3d45bba8275`: a corrupted slab freelist. The last victim, 12:39:06,
was `fuse_worker` of `lxcfs`. Everything reading lxcfs-backed `/proc` files then blocked: PAM
(container logins, host sshd, web authentication), `pvestatd` (hence `unknown`), and PID 1. FUSE
waits are killable, so the hung-task detector never fired.

The identical poisoned value in every oops points at one software corruption event; the kernel
was `6.17.4-1-pve`. The memory has no ECC, so the absence of MCE/EDAC errors does not exclude
hardware. `kernel.panic_on_oops` was 0, so the host degraded instead of rebooting, and with the GPU
passed through (`x-vga=1`), no serial console and no BMC there was no way in.

**Fix.**

- `kernel_panic_policy`: `kernel.panic_on_oops=1`, `kernel.panic=10`, read back from the running
  kernel ([decision](../decisions/hypervisor-panic-and-watchdog.md)).
- Alert rules `FilesystemMountTimeout` and `SystemdUnitStuckActivating` (a hung unit never becomes
  `failed`).
- Kernel: 6.17.13 installed 2026-10-08 with the PVE 9.2 upgrade and pinned; pin released
  2026-10-12, the host boots the 7.0 default since ([KE-14](#ke-14)).
- `softdog` not armed: that needs an HA resource, which on a single node fences the node itself.
  Revisit on a lockup with no oops and no netconsole frames, or when out-of-band access exists.
- Pending: `memtest86+` from the boot menu (needs physical presence).

**Verification.** Verified 2026-09-12: `sysctl kernel.panic_on_oops kernel.panic` returns 1 and 10.
Both rules returned empty on a healthy fleet and matched the incident series. After the reset all
guests returned with no failed unit; MariaDB replayed its InnoDB log cleanly. See
[hard shutdown recovery](../../runbooks/platform/hard-shutdown-recovery.md).

---

<a id="ke-22"></a>

## KE-22: A retired deployment stayed on disk and broke the backup seven months later

- **Status:** Resolved 2026-09-01
- **Affects:** lxc220 (Calibre-Web), `guest_backup`

**Symptom.** The first full guest backup, 2026-08-21, failed for lxc220:

```
tar: ./opt/calibreweb: Cannot open: Permission denied
```

`vzdump 220` exited non-zero and `guest_backup_failed_guests` read 1 until 2026-09-01.

**Cause.** Not the UID mapping, which is the Proxmox default and correct. `/opt/calibreweb` was the
deployment that `/srv/calibreweb` replaced in February, left in place and owned by host
`1000:1000`, outside the container's map (100000-165535). Inside the container its owner reads
`65534`, and container root gets `EACCES` because capabilities only reach mapped owners. `vzdump`
archives unprivileged containers through `lxc-usernsexec -m u:0:100000:65536`, so it reads only
what the container can read.

**Fix.** The directory (220 KB: old compose file, `app.db` with accounts all present in the live
database, a Flask key) was archived cold off the node, compared against live, and deleted. Removed
in the same pass: `/etc/systemd/system/tailscaled-userspace.service` ([KE-6](#ke-6)) and a stale
clone of this repository under `/opt`. The orphaned `smart.prom.*` temporary files in the host's
textfile directory were cleared on 2026-09-15 with the `smart_metrics` rollout.

**Verification.** `vzdump 220` wrote 1.03 GB in 33 s, exit 0; the next scheduled run ended
`status=0/SUCCESS` with `guest_backup_failed_guests 0`. The diagnosis is in the failure table of the
[guest backup runbook](../../runbooks/platform/guest-backup-restore.md).

---

<a id="ke-23"></a>

## KE-23: A role gained a task and seven nodes never received it

- **Status:** Resolved 2026-09-16
- **Affects:** `ssh_hardening`; lxc200, lxc210, lxc211, lxc220, lxc230, lxc260, vm102 (guests,
  2026-09-04) and the Proxmox host (2026-09-16)

**Symptom.** None visible. Measured 2026-09-04 with `sshd -T` and a directory listing: vm100,
lxc250 and the host had `sshd_config.d/00-hardening.conf`; seven guests had an empty
`sshd_config.d/`. Effective values were correct everywhere (`passwordauthentication no`,
`kbdinteractiveauthentication no`; `permitrootlogin no`, host `without-password`).

**Cause.** `6faf809` (2026-07-08) added the drop-in task to fix vm100 and was applied only there.
lxc250 and the host got it later on adoption. Debian's `sshd_config` starts with
`Include /etc/ssh/sshd_config.d/*.conf`, and sshd keeps the first value it reads, so a later file in
that directory would override the main file's lines. On vm100, `50-cloud-init.conf` had done
exactly that; `00-` sorts first.

**Fix.** Role applied to the nine guests on 2026-09-04 and to the host on 2026-09-16, the host run
behind a `systemd-run --on-active=300` dead-man switch. The host keeps `prohibit-password` from
`ansible/inventory/group_vars/proxmox.yml`. The weekly drift sweep reports such gaps
([remediation plan](remediation-plan.md#open-items)). Applying the role surfaced [KE-24](#ke-24).

**Verification.** `sshd -T` across all ten nodes matches the expected values; the drop-in is present
on every node; re-check at `changed=0`. Control status: A.8.5 in
[security controls](security-controls.md).

---

<a id="ke-24"></a>

## KE-24: sshd's reload is a re-exec, and under socket activation it cannot rebind

- **Status:** Resolved 2026-09-04
- **Affects:** `ssh_hardening` handler on socket-activated nodes (on 2026-09-04: lxc200, lxc210,
  lxc211, lxc220, lxc230, lxc260)

**Symptom.** After the [KE-23](#ke-23) run, `ssh.service` was `failed` on six containers while SSH
still worked. `sshd -T` exited 255 with `Missing privilege separation directory: /run/sshd`.

**Cause.** The Debian 12 template enables `ssh.socket` (`Accept=no`, `ListenStream=22`): systemd
holds port 22 and hands the descriptor to `ssh.service`, so both units active is correct. On
SIGHUP sshd re-execs itself and binds port 22 afresh instead of reusing the inherited descriptor;
systemd still holds it, so:

```
sshd[192]: Received SIGHUP; restarting.
sshd[192]: error: Bind to port 22 on 0.0.0.0 failed: Address already in use.
```

`RuntimeDirectory=` cleanup then removed `/run/sshd`, which broke `sshd -t` for a second reason.
The socket restarted the service on the next connection, so the fault repaired itself.

**Fix.** In the role: `ssh_hardening` reads `systemctl is-active ssh.socket` and uses `restarted`
where the socket is active and `reloaded` elsewhere; the reasoning is in the comment above the
detection task in `ansible/roles/ssh_hardening/tasks/main.yml`. Since 2026-10-10 the role also
disables `ssh.socket` wherever the bind is pinned, because `ListenAddress` has no effect under
socket activation ([sshd decision](../decisions/sshd-listen-address.md)).

**Verification.** Dry run 2026-09-04: six nodes select `restarted`, four `reloaded`, `changed=0` on
all nine guests.

---

<a id="ke-25"></a>

## KE-25: A UID map that exists only in the container's description

- **Status:** Resolved 2026-09-15; second instance 2026-10-08
- **Affects:** `guest_backup` and unprivileged containers holding files owned by unmapped host
  UIDs (seen on lxc210 and on the since-decommissioned Vaultwarden container)

**Symptom.** 2026-09-15: `guest-backup.service` exited 1, `guest_backup_failed_guests 1`:

```
tar: ./home/media/.bash_history: Cannot open: Permission denied
ERROR: Backup of VM 240 failed - command 'set -o pipefail && lxc-usernsexec
  -m u:0:100000:65536 -m g:0:100000:65536 -- tar cpf - ...' failed: exit code 2
```

**Cause.** `vzdump` reads the rootfs through the map the container declares, here the default
`u:0:100000:65536`. Paths under `/home/media` were owned by host UID 1000:

```
# find /var/lib/lxc/<vmid>/rootfs -xdev \( -uid -100000 -o -uid +165535 \) -printf '%U:%G %p\n'
```

`pct config` carried `description: Pin host UID 1000 <-> container UID 1000 (media)` but no
`lxc.idmap` entry: the mapping was never configured.

**Fix.** `chown -R 100000:100000` on the affected tree in the stopped container's rootfs, valid
because the account no longer logged in. On a live container the correct repair is the `lxc.idmap`
pair plus matching `/etc/subuid` and `/etc/subgid` entries.

Second instance, lxc210, 2026-10-08: 13,944 files of `/var/www/nextcloud` owned by host UID 1000,
8,228 with host GID 101000. They read `nobody:nogroup` in the container, so the Nextcloud updater
(`www-data`) could not replace them, and a host process running as UID 1000 could rewrite the PHP
Nextcloud executes. Fixed after a fresh `vzdump 210` by `chown -h 100033:100033` from the host.

**Verification.** 2026-09-15: the container's `vzdump` exited 0. 2026-10-08: all 39,354 entries
read `100033:100033`, `occ integrity:check-core` clean, Nextcloud upgrade ran on that tree.

---

<a id="ke-26"></a>

## KE-26: The wake alarm was programmed for the right time on the wrong day

- **Status:** Resolved 2026-09-25
- **Affects:** Proxmox host, `homelab-setwake.sh` (role `homelab_schedule`)

**Symptom.** The host powered down every night and then stayed off until switched on by hand. The
boot history showed six starts, one at a scheduled time, against shutdowns that never varied.
Measured 2026-09-17: `/sys/class/rtc/rtc0/wakealarm` was empty after the alarm should have fired.

**Cause.** The script then ran from cron at 00:45, after midnight, and computed its target with
`date -d tomorrow`: a host shutting down early Thursday was told to wake Friday. The weekday test
had the same offset. `rtcwake` accepts a far-future time and exits 0, and the host was usually
switched on by hand before the alarm came due.

**Fix.** `homelab-setwake.sh` is called by `homelab-shutdown.sh` immediately before power-off. It
computes the next start from `homelab_schedule_plans` in the role defaults, starting with today,
requires at least 600 s of lead time, and reads the alarm back from
`/sys/class/rtc/rtc0/wakealarm`. The read-back allows 60 s either way: `rtcwake` subtracts the
RTC-to-system-clock difference read across a second boundary and can arm one second early
(`alarm reads 1790314199 ..., expected 1790314200`). Both host scripts run through `systemd-cat`,
so output reaches the journal instead of cron's local mailer.

**Verification.** The host woke by RTC at 07:31:14 on 2026-09-25. Each night leaves a line in
`journalctl -t homelab-setwake`; success reads `wakealarm armed for <time>`.

---

<a id="ke-27"></a>

## KE-27: A container whose start fails at boot stays down until someone starts it

- **Status:** Mitigated 2026-10-03 - retry not yet exercised by a real failure
- **Affects:** vm100 containers that bind a CIFS automount or need the NVIDIA prestart hook
  (Jellyfin, Audiobookshelf, `llama-server`)

**Symptom.** After boot, the container is `Exited (128)` while Docker and the other containers run.
`docker inspect` shows the reason in `State.Error`:

```text
OCI runtime create failed: ... error mounting "/srv/media/filme" to rootfs at "/media/Filme": ... no such device
```

**Cause.** `restart: unless-stopped` reacts to a container that ran and exited. A start that fails
in `runc create` never runs, so dockerd tries once while restoring containers and stops. Journal
instances (`journalctl -u docker.service | grep "failed to start container"`):

```text
2026-08-05 22:50  prestart hook #0: ... nvidia-container-cli: initialization error: nvcgo rpc error: timed out
2026-08-24 22:55  prestart hook #0: ... nvidia-container-cli: initialization error: nvcgo rpc error: timed out
2026-09-29 10:19  error mounting "/srv/media/filme" ...      (and "/srv/media/audiobooks")
2026-10-03 09:02  error mounting "/srv/media/filme" ...
```

2026-09-29: vm102 unreachable (`cifs_mount failed w/return code = -113`). 2026-10-03: vm102 up;
vm100 logged `Send error in SessSetup = -11` 12 ms after another share's mount started. Working
explanation, unproven: two session setups for different users collided on the CIFS client's
single connection to vm102.

`docker_mount_ordering` orders Docker after the automount trigger, which says nothing about the
mount succeeding. Ordering Docker after the mounts themselves would tie it to vm102 being up
([KE-15](#ke-15)).

**Fix.** Role `docker_boot_retry` (`snippets/scripts/docker-boot-retry.sh`): a unit after
`docker.service` runs once per boot and starts every exited container with policy `always` or
`unless-stopped` and a non-empty `State.Error`; six passes, 30 s apart. If something is still down,
the unit fails and `SystemdUnitFailed` reports it. `docker stop` leaves `State.Error` empty, so
deliberately stopped containers are not touched.

**Verification.** Applied 2026-10-03, re-check `changed=0`; selection tested against the live node
(nothing to start) and four synthetic rows. Proof of a real retry: a
`started <name> (attempt n/6)` line in `journalctl -b -t docker-boot-retry`. Related:
[KE-18](#ke-18), [KE-28](#ke-28), [vm100](../nodes/vm100.md).

---

<a id="ke-28"></a>

## KE-28: Jellyfin streams stalled inside the `tailscale serve` TCP forwarder

- **Status:** Resolved 2026-10-07
- **Affects:** Jellyfin on vm100, 2026-10-01 to 2026-10-07, while published on `127.0.0.1` behind
  `tailscale serve --tcp 8096`; client a media player (`tag:media-player`) on a direct path

**Symptom.** Playback loads and never starts, or stops after seconds; browsing works. Jellyfin
logged `Playback stopped ... Stopped at "3890" ms`. In the afternoon instance the attempts did not
reach Jellyfin at all (no entry 10:51:41 to 15:34), while `/health` on loopback answered `200` in
3 ms and `tailscale ping` answered in 1 ms.

**Cause.** `tailscale serve --tcp` terminates the client connection in `tailscaled`'s userspace
netstack and copies bytes to a second connection on loopback. The stream stopped between the two.
Both loopback ends during a stall, unchanged over three readings:

```text
$ ss -tnp | grep 52868
ESTAB 0       4116981 127.0.0.1:8096   127.0.0.1:52868 users:(("docker-proxy",pid=1896,fd=9))
ESTAB 5865362 0       127.0.0.1:52868  127.0.0.1:8096  users:(("tailscaled",pid=851,fd=39))
```

`tailscaled` held 5.8 MB unread (`Recv-Q`) and refused new connections from the client
(`netstack: decrementing connsInFlightByClient[...] because the packet was not handled`: 52 lines
at 10:00, 8 at 15:00). Which netstack limit tripped was not established. The rollout had been
validated with an SMB transfer over the kernel path through `tailscale0`, which never touches the
forwarder.

**Fix.** 2026-10-07 15:34: `tailscale serve --tcp=8096 off`; Jellyfin publishes on
`${JELLYFIN_BIND_ADDR}` (vm100's Tailscale address) in `docker/jellyfin/docker-compose.yml`.
`tailscaled` runs in kernel mode on vm100, so the kernel carries TCP. `docker.service` waits for the
address through `tailscale_boot_gate`, with `docker_boot_retry` ([KE-27](#ke-27)) as backstop
([KE-18](#ke-18)).

**Verification.** Same client and episode, 15:38: throughput 62-95 Mbit/s (64-99 through `serve`),
`tailscaled` CPU 49-82 % (90-154 %), no new `connsInFlight` lines after 15:27:40. Cold boot
2026-10-10: Jellyfin up with no `docker-boot-retry` line; the gate held again on 2026-10-13. Audiobookshelf and
`llama-server` still sit behind `serve` on loopback and have not shown the fault. Not yet measured:
three concurrent 4K streams. See [jellyfin.md](../services/jellyfin.md).
