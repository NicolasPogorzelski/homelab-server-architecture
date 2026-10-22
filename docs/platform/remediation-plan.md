# Remediation Plan

The register of open platform work, ranked by loss risk and dependency. Each row names the risk of
leaving the item and the next step. Items whose next step needs more than one sentence have a short
section below the table. Closed items are removed; the pull request that closed them is the record.
The ISO/IEC 27001 reading of the same gaps is in [`security-controls.md`](security-controls.md).

## Open items

| Rank | Item | Risk if left | Next step |
|---|---|---|---|
| 1 | [Off-site backup](#off-site-backup) | Every copy of the C1 data is on one site; fire, theft or ransomware reaching the SMB mounts destroys originals and backups together | Provision the VPS with [`offsite-vps-provision.md`](../../runbooks/platform/offsite-vps-provision.md), then deploy the `offsite_backup` role |
| 2 | [Boot SSD replacement](#boot-ssd-replacement) ([KE-14](known-errors.md#ke-14)) | The disk carrying Proxmox and every guest root disk logs I/O errors in operation | Replace it in the second half of October 2026 with [`boot-ssd-replacement.md`](../../runbooks/platform/boot-ssd-replacement.md) |
| 3 | [Escrow restore drill](#escrow-restore-drill) | The escrow of the vault password, the real inventory and the Ansible SSH key has never been restored from; a gap would be found on the day lxc250 is lost | Run [`escrow-restore-drill.md`](../../runbooks/platform/escrow-restore-drill.md) once and record the result |
| 4 | SSH host key checking in Ansible | `ansible/ansible.cfg` sets `host_key_checking = False`, so a spoofed node is not detected and receives every secret the playbooks deploy to it | Record each node's host key in the control node's `known_hosts` from the inventory, then remove the setting |
| 5 | [aux-disk replacement and disposal](#aux-disk-replacement-and-disposal) ([KE-13](known-errors.md#ke-13)) | The guest backups and the Docker data roots sit on a disk with a growing count of unreadable sectors | Order the replacement and decide the disposal method before it arrives |
| 6 | [External heartbeat](#external-heartbeat) | A total outage of the host or of lxc200 produces silence, not an alert | Choose a third-party heartbeat receiver and deploy its route in the live `alertmanager.yml` |
| 7 | [Power path and UPS](#power-path-and-ups) | The leading KE-14 hypothesis is the 12 V rail; the UPS has never been tested under load | Record the UPS and measure its runtime; run [`ke14-power-path-check.md`](../../runbooks/platform/ke14-power-path-check.md) if errors persist after rank 2 |
| 8 | [Storage network](#storage-network) | SMB from vm100 and the hypervisor to vm102 crosses the LAN, filtered by source address only | Write the decision record for a host-only bridge before any live change |
| 9 | Automation key separate from the break-glass key | Automated work on the admin workstation authenticates with the break-glass key, so an automated process holds the access reserved for a person in an emergency | Create a restricted key and account for automated work, the way Ansible has `ansible`, and keep the break-glass key for people |
| 10 | Data protection reassessment | One external user reaches Jellyfin, Audiobookshelf and Nextcloud through machine sharing; the household exemption in [`data-classification.md`](data-classification.md#data-protection-assessment) may no longer cover those services | Redo the assessment for the three services and record the result there |
| 11 | Retention and deletion policy | No retention period exists for documents, logs or monitoring history (A.8.10) | Write retention periods per class into [`data-classification.md`](data-classification.md#retention-and-deletion) |
| 12 | [Identity track](#identity-track) | Every service keeps its own accounts; Terraform waits on this track | Choose a start date, then build the identity node per [the decision](../decisions/identity-before-terraform.md) |
| 13 | Nextcloud 35 needs Debian 13 on lxc210 | Nextcloud 34 is the last major that runs on Debian 12's PHP 8.2 and is supported until 2027-06 | Upgrade lxc210 to Debian 13, then run `occ maintenance:repair --include-expensive` in its own window |
| 14 | Trailers and the Letterboxd diary after Jellyfin 12 | Cinema Mode and LetterboxdSync have no build for 12, so trailers before films and the diary sync are gone | Install Jellyscribe for the diary; read the code of Trailer Preroll 2.x, which downloads from YouTube and has a single maintainer, before it runs on the GPU node |
| 15 | Apache on lxc210 binds the wildcard address | `lan_guard` closes the LAN side, but the binding rule stays broken on 80 and 443 | Move Nextcloud behind `tailscale serve`, which also retires [KE-16](known-errors.md#ke-16) |
| 16 | [Package supply track](#package-supply-track), stages 1 to 4 and 6 | Every node fetches packages and images from public sources itself; nothing records or controls what enters the fleet, and an egress filter cannot be built | Read the theory of stage 1, then record every package source per node |
| 17 | [Egress filter](#package-supply-track), stage 5 | No guest is limited in the outbound connections it opens, and the hypervisor firewall is disabled; a compromised service can reach any address | After stage 4, list per guest the outbound destinations it needs, then write the decision record |

## Item notes

### Off-site backup

Target decided in [`offsite-backup-target.md`](../decisions/offsite-backup-target.md): a small VPS
running `rest-server` in append-only mode, written to by `restic`. Scope is the C1 set in
[`data-classification.md`](data-classification.md).

The `offsite_backup` role, its playbook, the alert rules and two runbooks exist. Each source node
gets its own repository and append-only account, so a compromise of vm102 cannot read the
credentials lxc250 holds. The playbook stays excluded from the drift sweep (`ansible/drift-sweep.conf`)
until the target exists.

1. Provision the VPS with [`offsite-vps-provision.md`](../../runbooks/platform/offsite-vps-provision.md).
2. Apply `offsite-backup.yml` and move it from `[excluded]` to `[playbooks]` in the sweep.
3. Restore once from the VPS per [`offsite-backup.md`](../../runbooks/backup/offsite-backup.md).

Residual risk, accepted in the decision: root on the VPS can still delete the repositories.

### Boot SSD replacement

The replacement is a rebuild, not a clone: Proxmox installed fresh on the new disk and the platform
restored with [`platform-restore.md`](../../runbooks/platform/platform-restore.md). It is the first
full restore test, and the old SSD stays untouched as the rollback.

Decide the port before the swap. The same HBA port and cable separates the media from the
transport; an onboard SATA port separates the HBA path from the power and gives the SSD the TRIM
the HBA blocks. The per-boot count of failed commands before and after is the KE-14 test.

### Escrow restore drill

The escrow exists since 2026-08-20: a password manager operated by a third party, plus a paper copy
off site. Two of the three artefacts are files (`hosts.yml` and the Ansible SSH key), so the drill
confirms that the escrow holds them, not only the vault password. After the first run, repeat it
yearly and record each run in the runbook's execution log.

### aux-disk replacement and disposal

The aux-disk carries `/mnt/vzdump` (the guest backups), the Docker data roots and vm100's data disk.
[`aux-disk-failure-rescue.md`](../../runbooks/storage/aux-disk-failure-rescue.md) covers moving the
data off it.

Disposal is part of the item. The disk holds C1 application data, and with thousands of unreadable
sectors a software overwrite cannot be assumed to reach every block. The options are degaussing or
physical destruction, decided before the disk is removed (A.7.14 in
[`security-controls.md`](security-controls.md)).

### External heartbeat

The `Watchdog` rule fires permanently and is loaded. The route that sends it to an external
receiver instead of Discord exists only in
[`alertmanager.yml.example`](../../docker/monitoring/alertmanager/alertmanager.yml.example); the
live file on lxc200 still has the single Discord route (measured 2026-09-24).

1. Sign up for a heartbeat service operated by a third party; a self-hosted receiver would need a
   watcher of its own.
2. Set its grace period above the nightly off-window (`homelab_schedule` defaults), or every
   morning opens with an alarm.
3. Deploy the route and the receiver URL in the live `alertmanager.yml` together.

### Power path and UPS

[`physical-controls.md`](physical-controls.md) names supporting utilities as the weakest physical
control. Record the UPS model, age and battery date, and measure one runtime under real load. The
KE-14 power-path check runs only if the errors follow the new boot SSD (rank 2); it needs host
downtime and no purchase.

### Storage network

SMB from vm100 and the hypervisor reaches vm102's LAN address, admitted by `smb_guard` and by the
`lan_guard` exception in `ansible/inventory/host_vars/vm102.yml`. The target replaces step 2 of
[`smb-bind-and-lan-access.md`](../decisions/smb-bind-and-lan-access.md):

- a host-only bridge `vmbr1` without `bridge-ports`, static addresses for the host, vm100 and vm102;
- the host mounts and vm100's mounts move to it one at a time, each with automount and a reboot
  test;
- afterwards `smb_guard` drops 445 on vm102's LAN interface and the `lan_guard` exception for 445
  is removed.

Samba keeps its wildcard bind, because an explicit bind cuts the Tailscale path the admin
workstations use; check that path after every step. The ACL does not change. In the same window,
adopt the hand-deployed `smb-guard` table (`snippets/storage/smb-guard.nft`) into the `nft_guard`
role.

Verified 2026-10-01: SMB over Tailscale from the admin desktop at 94.9 MB/s up and 104.9 MB/s down
with `smbclient`; neither of vm102's two vCPUs saturated. On 1 GbE the link and the tunnel set the
ceiling.

### Identity track

Status Proposed in [`identity-before-terraform.md`](../decisions/identity-before-terraform.md); its
start condition, the exercise block applied, is met. Order:

1. The node: container, `onboarding.yml`, roles for `lldap` and Authelia, both databases through
   `postgresql_provisioning` on lxc260, Tailscale tag and ACL rule, node and service documents,
   scrape targets.
2. The clients: Grafana, OpenWebUI, Paperless-ngx and Jellyfin are the minimum that gates
   Terraform; Audiobookshelf and Calibre-Web follow. Nextcloud and Proxmox VE are deferred for the
   reasons in the decision.

### Package supply track

A learning track as well as a fix: each stage starts with the theory it needs, written up before
any configuration exists. Stages 3, 4 and 6 are exercises in the sense of
[`exercise-scope-before-terraform.md`](../decisions/exercise-scope-before-terraform.md).

**In place.** Security-only `unattended_upgrades` with kernels and the NVIDIA stack held back;
`apt-upgrade.yml` for the rest; `apt_metrics` and `AptSecurityUpdatesPending`; a weekly
`dpkg --verify` projection in `fleet_snapshot`; compose images pinned by tag, one by digest; the
weekly Trivy scan; the monthly SBOM and signature check; Actions pinned to SHAs under Dependabot.

Verified 2026-10-22: no APT proxy on any node; no nftables output chain on any node drops or
rejects, every one accepts by policy; `pve-firewall status` reports `disabled/running`; by Ansible
ad-hoc from lxc250. Third-party APT sources: Tailscale on every node, Docker on lxc200, lxc211,
lxc220, lxc230 and vm100, NVIDIA container toolkit and the graphics-drivers PPA on vm100, HashiCorp
on lxc250. Every third-party list except the PPA names its key with `signed-by`.

1. **Trust chain and inventory.** How APT trusts a package (`InRelease`, the hash chain from
   `Release` to `Packages` to the `.deb`, `signed-by` keyrings) and how it chooses a version
   (`apt-cache policy`, pinning) are covered by [SecureApt](https://wiki.debian.org/SecureApt), the
   [repository format](https://wiki.debian.org/DebianRepository/Format) and `man apt_preferences`.
   The package sources per node then go into the node documents, and the PPA is bound to its key
   with `signed-by`.
2. **APT cache.** A caching proxy and a mirror differ in what they store and when; HTTPS sources
   need their own handling behind a proxy, and the cache becomes a single point of failure for
   patching ([apt-cacher-ng manual](https://www.unix-ag.uni-kl.de/~bloch/acng/)). A decision record
   comes first, then the `apt-cacher-ng` container, a role that sets `Acquire::http::Proxy` on every
   node, and a scrape target or alert for the cache.
3. **Offline install drill (exercise).** An air-gapped site gets packages by downloading them on an
   identical system, transferring them with checksums and importing them into a local repository
   ([aptly overview](https://www.aptly.info/doc/overview/)). One disposable container without a
   route out receives a package that is not cached, and the steps become a runbook.
4. **Staged rollout from snapshots (exercise).** Fleets freeze a package set, test it on one node
   and promote it after. Here an `aptly` snapshot is published through the cache, tried on one
   guest, then the fleet.
5. **Egress filter.** Default-deny outbound with an allowlist per role, read in the
   [Proxmox VE firewall](https://pve.proxmox.com/wiki/Firewall) documentation,
   [Tailscale firewall ports](https://tailscale.com/kb/1082/firewall-ports) and the
   [nftables wiki](https://wiki.nftables.org/). Known needs: Tailscale coordination and DERP on
   every node, registries and media metadata on vm100, the off-site target, the issuer for
   `tailscale_cert`, NTP for `chrony`. The decision record precedes the filter, which is applied one
   guest at a time; it must not flush Tailscale's chains
   ([`smb-bind-and-lan-access.md`](../decisions/smb-bind-and-lan-access.md)), and LAN SSH to the
   hypervisor stays the recovery path.
6. **Container images (exercise).** A tag can move, a digest cannot; `registry-mirrors` in the
   Docker daemon covers Docker Hub only
   ([pull-through cache](https://distribution.github.io/distribution/recipes/mirror/)); provenance
   is the subject of [Sigstore cosign](https://docs.sigstore.dev/) and [SLSA](https://slsa.dev/).
   Every compose image ends pinned by digest, and a decision says whether a pull-through registry
   is worth running here.

## Deferred on purpose

- **Alertmanager routing and per-tier dashboards.** The alerts exist; delivery is a single channel.
- **Molecule and a test estate.** Out of scope until the Terraform track; `--check --diff` and the
  drift sweep stand in (A.8.29 and A.8.31 in [`security-controls.md`](security-controls.md)).
- **KE-3, KE-11, KE-17.** Non-blocking, or no confirmed root cause to act on.
- **[KE-10](known-errors.md#ke-10), Jellyfin CUDA loss.** No root cause. The watchdog restarts
  Jellyfin only while no direct stream plays; `JellyfinCudaLost` reports a held or failed restart.
- **High availability.** Stays at reading on a single node; see [`ha-mechanics.md`](ha-mechanics.md).
