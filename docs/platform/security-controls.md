# Security Controls - ISO/IEC 27001 Annex A Mapping

A self-assessment of this platform against ISO/IEC 27001:2022 Annex A, as elaborated in
ISO/IEC 27002:2022. It maps controls and claims no compliance. Certification covers clauses 4-10,
the management system (scope, risk assessment, Statement of Applicability, internal audit,
management review), and a platform run by one person has neither an independent auditor nor a
management review. What the mapping does is separate controls that a machine enforces from
practices that depend on someone remembering them.

Open work behind every Partial and Gap row is ranked in the [remediation plan](remediation-plan.md).
The controls built as exercises ([decision](../decisions/exercise-scope-before-terraform.md)) -
syscall auditing, central log aggregation, high availability, SBOM with signature verification -
appear at most as Practised, with the exercise named in the row.

## Status

| Status | Meaning |
|---|---|
| **Enforced** | A machine refuses or reports the wrong outcome. Skipping it requires disabling something, which leaves a trace. Every Enforced row cites its evidence. |
| **Practised** | Done consistently and documented, but nothing prevents an exception. |
| **Partial** | Implemented for part of the estate, or with a known blind spot. |
| **Gap** | Not implemented. Listed with its consequence. |
| **N/A** | Not applicable, with the reason. |

## Organizational controls (A.5)

| Control | Status | Evidence | Residual risk |
|---|---|---|---|
| A.5.1 Policies for information security | Partial | Binding rules are stated in [`CONVENTIONS.md`](../CONVENTIONS.md), the binding rules in [`tailscale-acl.md`](tailscale-acl.md) and this file. | The rules are spread over several documents; no single policy document exists. |
| A.5.2 Roles and responsibilities | N/A | One person holds every role. | Bus factor 1; documentation and runbooks are the only compensation. |
| A.5.3 Segregation of duties | N/A | Impossible with one person; the pull-request flow forces a re-read of every change as a diff. | No second reviewer sees any change. |
| A.5.7 Threat intelligence | Partial | Dependabot security updates ([`dependabot.yml`](../../.github/dependabot.yml)) and the weekly [image scan](../../.github/workflows/image-scan.yml). | Nothing covers threats beyond published package advisories. |
| A.5.9 Inventory of assets | Practised | All ten nodes in [`hosts.yml.example`](../../ansible/inventory/hosts.yml.example), one document per node under [`docs/nodes/`](../nodes/); client devices by tag in [`tailscale-acl.md`](tailscale-acl.md). | Client devices are listed by role only, without a per-device record. |
| A.5.12 Classification of information | Partial | Three classes and recovery objectives in [`data-classification.md`](data-classification.md). | The classes drive the off-site scope but no other technical control. |
| A.5.13 Labelling of information | N/A | No data is handled by people who did not create it; the classification table carries the same information. | None at this scale. |
| A.5.14 Information transfer | Partial | Remote access and service-to-service traffic run over Tailscale (WireGuard). SMB from vm100 and the hypervisor to vm102 runs over the LAN, admitted only from those two sources by `smb_guard` ([`samba.md`](samba.md)) and `lan_guard`. Netconsole from vm100 to the hypervisor also uses the LAN. | LAN SMB traffic is not encrypted by the overlay; removed by the storage network item in the [remediation plan](remediation-plan.md#storage-network). |
| A.5.15 Access control | Enforced | Per-tag and per-host grants, deny by default, with policy tests that make Tailscale reject an edit breaking an assertion: [`tailscale-acl.md`](tailscale-acl.md). | The admin console is the source of truth and the repository copy is applied by hand, so the two can drift. |
| A.5.16 Identity management | Practised | A dedicated `ansible` user on every guest, separate from the per-node admin account; per-service accounts. | No central identity; the identity track is Proposed ([decision](../decisions/identity-before-terraform.md)). |
| A.5.17 Authentication information | Partial | Secrets in Ansible Vault (`ansible/inventory/group_vars/all/vault.yml`); vault password, real inventory and Ansible SSH key escrowed off site. | The escrow has never been restored from ([`escrow-restore-drill.md`](../../runbooks/platform/escrow-restore-drill.md)). |
| A.5.18 Access rights | Partial | `breakglass` enforces the VM admin accounts' keys with `exclusive: true` and removes passwordless sudo and root-equivalent groups (`ansible/roles/breakglass/`); `ssh_hardening` deletes root's `authorized_keys` wherever root login is refused. | No role manages the hypervisor root account's four keys. |
| A.5.19, A.5.20, A.5.22 Supplier relationships | N/A | No suppliers, contracts or outsourced processing. | None. |
| A.5.21 ICT supply chain | Partial | Every GitHub Action is pinned to a commit SHA and updated by Dependabot. Every compose file pins its images. A monthly SBOM and signature check runs as an exercise ([`sbom.yml`](../../.github/workflows/sbom.yml)), report only. | Most images are unsigned community builds, and nothing refuses an unsigned image. |
| A.5.23 Security for cloud services | N/A | No cloud service in the platform path. | Revisit when the off-site VPS or the Terraform track goes live. |
| A.5.24 Incident management planning | Practised | [Runbooks](../../runbooks/README.md) per failure class and the [known-error register](known-errors.md). | Most runbooks have never been exercised. |
| A.5.25 Assessment and decision on events | Practised | Every known error records cause and decision: fix, accept or defer with a reason. | Assessment depends on someone reading the alert. |
| A.5.26 Response to incidents | Practised | Procedures exist for the failure classes that have occurred. | Classes that have not occurred have no tested procedure. |
| A.5.27 Learning from incidents | Practised | Known errors record the failure class as well as the fix; post-mortems in [`incidents/`](incidents/). | Lessons apply only where someone sweeps the fleet for the same class. |
| A.5.28 Collection of evidence | Practised | Known errors and runbooks record commands and their measured output, dated. | Evidence is protected only by git history. |
| A.5.29 Security during disruption | Partial | [`platform-restore.md`](../../runbooks/platform/platform-restore.md) rebuilds host and guests from backups; `plan` and `test-restore` run against live backups. | Loss of the whole host has not been exercised; the boot SSD replacement is the first full rebuild. |
| A.5.30 ICT readiness for continuity | Partial | Monthly restore tests for PostgreSQL and MariaDB with staleness alerts ([`pg-restore.md`](../../runbooks/database/pg-restore.md), [`mariadb-restore.md`](../../runbooks/database/mariadb-restore.md)); guest restore exercised 2026-08-21; objectives in [`data-classification.md`](data-classification.md). | No off-site copy exists. |
| A.5.31 Legal and regulatory requirements | Partial | [`LICENSE`](../../LICENSE); data protection in [`data-classification.md`](data-classification.md). | The data protection assessment is due again for shared services. |
| A.5.33 Protection of records | Enforced | Records live in git; `main` cannot be force-pushed or deleted, and commits are SSH-signed (`git log --show-signature`). | The owner can disable the ruleset, which GitHub records. |
| A.5.34 Privacy and PII | Partial | Assessed in [`data-classification.md`](data-classification.md#data-protection-assessment). | One external user has access to three services that the assessment has not been redone for. |
| A.5.35 Independent review | Gap | Structurally unavailable; the weekly drift sweep and fleet snapshot are self-review. | No outside party checks anything. |
| A.5.36 Compliance with policies | Enforced | [`validate-repo.sh`](../../scripts/validate-repo.sh) runs in CI ([`validate-repo.yml`](../../.github/workflows/validate-repo.yml)) on every push to and pull request against `main`, and is required for merge. | It checks structure and patterns, not whether a statement is true. |
| A.5.37 Documented operating procedures | Enforced | The repository validator fails a runbook without its contract sections (Preconditions, Verification, Failure modes, Rollback); contract in [`runbooks/README.md`](../../runbooks/README.md). | A section can be present and still be wrong. |

## People controls (A.6)

| Control | Status | Evidence | Residual risk |
|---|---|---|---|
| A.6.1, A.6.2, A.6.4-A.6.6 Screening, terms, disciplinary, after termination | N/A | No employment relationship exists. | None. |
| A.6.3 Awareness and training | N/A | No staff. | None. |
| A.6.7 Remote working | Enforced | Administration runs over Tailscale with key-only SSH; `ssh_hardening` writes `00-hardening.conf` on all ten nodes (`ansible/roles/ssh_hardening/`), and `lan_guard` limits the hypervisor's LAN SSH to the two admin workstations. | The hypervisor's LAN break-glass path bypasses Tailscale, so SSH survives a Tailscale outage. |
| A.6.8 Reporting information security events | Practised | Reporting channel in [`SECURITY.md`](../../.github/SECURITY.md). | No response time is guaranteed. |

## Physical and environmental controls (A.7)

What holds each control, and the two decisions behind it (no encryption at rest, `pve-firewall`
off), are in [`physical-controls.md`](physical-controls.md).

| Control | Status | Evidence | Residual risk |
|---|---|---|---|
| A.7.1 Physical security perimeter | Partial | The site entrance. | No second boundary between the entrance and the machine. |
| A.7.2 Physical entry | Partial | Occupants only. | No entry record. |
| A.7.3 Securing offices and rooms | Gap | No dedicated, lockable room. | Anyone with access to the site can reach the machine. |
| A.7.4 Physical security monitoring | Gap | No camera, door contact or tamper seal. | Physical tampering would go unnoticed. |
| A.7.5 Physical and environmental threats | Partial | Smoke detection. | No water detection or fire suppression near the machine. |
| A.7.8 Equipment siting and protection | Partial | Off the floor, clear airflow. | Not in a locked enclosure. |
| A.7.10 Storage media | Partial | Disks are not encrypted at rest, by decision. | Anyone holding the disks can read the C1 data. |
| A.7.11 Supporting utilities | Gap | A consumer UPS, never load-tested; the power path is the leading [KE-14](known-errors.md#ke-14) hypothesis. | A mains event or a sagging rail can take down every guest at once. |
| A.7.12 Cabling security | Partial | Internal cabling reseated during the KE-13 diagnosis. | Cabling is undocumented. |
| A.7.13 Equipment maintenance | Partial | `smart_metrics` on the hypervisor exports every SMART attribute of every disk it sees; `SmartAttributeDegrading` fires on any counter rising within 25 hours; SnapRAID scrub runs weekly (`snapraid_maintenance`). | Physical maintenance is reactive. |
| A.7.14 Secure disposal or re-use | Gap | No disposal procedure; the KE-13 disk is due for replacement and holds C1 data on sectors an overwrite cannot reach. | Data leaves the site with a disposed disk unless the method is decided first. |

## Technological controls (A.8)

| Control | Status | Evidence | Residual risk |
|---|---|---|---|
| A.8.1 User endpoint devices | Partial | The admin workstations run an immutable, image-based OS. | Endpoint hardening is otherwise undocumented. |
| A.8.2 Privileged access rights | Partial | Automation uses the `ansible` user; `PermitRootLogin no` on all nine guests and `prohibit-password` on the hypervisor, where root is the only admin account (`ansible/inventory/group_vars/proxmox.yml`); `breakglass` refuses passwordless sudo on the VMs. | Automated work on the admin workstation uses the break-glass key ([remediation plan](remediation-plan.md)). |
| A.8.3 Information access restriction | Enforced | Deny-by-default ACL with per-host grants in [`tailscale-acl.md`](tailscale-acl.md); each node document states its tag, checked by the repository validator. | A service on a wildcard bind is reachable by every source the ACL admits to that node. |
| A.8.4 Access to source code | Enforced | `main` requires a pull request with passing checks ([`.github/workflows/`](../../.github/workflows/)), blocks force-pushes and deletion, and has no bypass actors. | The owner can disable the ruleset, which GitHub records. |
| A.8.5 Secure authentication | Enforced | `ssh_hardening` writes `PasswordAuthentication no` in `00-hardening.conf` on all ten nodes, which wins over later drop-ins; the weekly drift sweep fires `FleetDriftUnexpected` on divergence. Verified 2026-09-04 with `sshd -T` on every node. | Divergence between two sweeps goes unnoticed for up to a week. |
| A.8.6 Capacity management | Enforced | `DiskSpaceCritical`, the `LvmThinPool*` rules and `ArchivePoolLowSpace` in [`alert.rules.yml`](../../docker/monitoring/prometheus/rules/alert.rules.yml). | Alerts report a level, not a trend; expansion is planned by hand. |
| A.8.7 Protection against malware | N/A | No interactive users and no public ingress on a Linux fleet; pinned images, least privilege and network isolation are the measures. | A compromised image would not be detected by a scanner on the node. |
| A.8.8 Management of technical vulnerabilities | Partial | `apt_metrics` and `AptSecurityUpdatesPending` on all ten nodes; security-only unattended upgrades on every guest, kernels and the NVIDIA stack held back (`unattended_upgrades`); weekly Trivy image scan. | The hypervisor, held-back kernels and Docker-repository packages are patched by hand with `apt-upgrade.yml`. |
| A.8.9 Configuration management | Enforced | All ten nodes, hypervisor and control node included, are in the inventory; the weekly drift sweep (`ansible/drift-sweep.conf`) fires `FleetDriftUnexpected`, and `fleet_snapshot` diffs what no role owns. | State outside every role (guest and storage configuration in `/etc/pve`, the Tailscale policy) is diffed weekly, not alerted on. |
| A.8.10 Information deletion | Gap | No retention or deletion policy. | Data is kept indefinitely or lost by accident, never removed by rule. |
| A.8.11 Data masking | N/A | No shared or exported datasets. | None. |
| A.8.12 Data leakage prevention | Enforced | Sanitization checks in [`validate-repo.sh`](../../scripts/validate-repo.sh), gitleaks over the full history ([`secret-scan.yml`](../../.github/workflows/secret-scan.yml)), GitHub secret scanning with push protection ([`SECURITY.md`](../../.github/SECURITY.md)). | Pattern matching misses a secret that does not look like one. |
| A.8.13 Information backup | Partial | Verified daily dumps (`postgresql_backup`, `mariadb_backup`), monthly restore tests, weekly guest backup and daily host configuration backup (`guest_backup`). | Every copy is on site, and the guest backups sit on the failing aux-disk. |
| A.8.14 Redundancy | N/A | Single host; SnapRAID parity protects media against disk loss, not processing. High availability was read, not armed ([`ha-mechanics.md`](ha-mechanics.md)). | A host failure is an outage until hardware is replaced. |
| A.8.15 Logging | Partial | `journald` sets `Storage=persistent` and a size cap on all ten nodes (`ansible/roles/journald/`). Exercises: central journal collection on lxc200 from lxc211 and lxc260, `auditd` on the hypervisor. | No tamper protection, and the central store shares the host's failure domain. |
| A.8.16 Monitoring activities | Enforced | Node, service and unit alerts including absence alerts (`SnapRAIDSyncStale`, `PostgreSQLRestoreTestStale`, `ListenerOutsideBindingRule`) in [`monitoring.md`](monitoring.md). | Monitoring runs on the host it watches; a total outage is silent until the external heartbeat is live. |
| A.8.17 Clock synchronization | Partial | `chrony` role on vm100 and vm102 (`ansible/roles/chrony/`); containers use the hypervisor's kernel clock. | The hypervisor's time daemon is not role-managed, and no alert watches clock offset. |
| A.8.18 Use of privileged utility programs | Partial | Maintenance scripts are deployed by roles to `/usr/local/sbin`, owned by root. | No restriction beyond file permissions. |
| A.8.19 Software on operational systems | Partial | Packages are installed by roles and images are pinned; `fleet_snapshot` shows unmanaged changes in a weekly diff. | Ad-hoc installation remains possible and is seen only in the diff. |
| A.8.20 Networks security | Enforced | No public ingress or port forwarding (router checked 2026-09-26); `lan_guard` drops new inbound LAN connections on every node except named exceptions (`ansible/roles/lan_guard/`); model in [`networking.md`](networking.md). | A manual restart of `nftables.service` flushes the `lan_guard` table until the next boot. |
| A.8.21 Security of network services | Partial | Services bind loopback or the Tailscale address; sshd is pinned on all nine guests. `listener_metrics` reports every listener outside that rule and `ListenerOutsideBindingRule` fires on any not recorded as an exception in the inventory. Recorded exceptions: Samba on vm102, Apache and `coolwsd` on lxc210 (`coolwsd` behind `nft_guard`), sshd and netconsole on the hypervisor ([decision](../decisions/sshd-listen-address.md)). | Apache on lxc210 still binds the wildcard address. |
| A.8.22 Segregation of networks | Enforced | Tailnet segregation by tag and host grant, deny by default ([`tailscale-acl.md`](tailscale-acl.md)): only the hypervisor and Nextcloud reach `tag:storage:445`, only Paperless and the AI stack reach `tag:database:5432`, and no grant has vm100 or vm102 as its source. | All nodes share one LAN segment; separation there rests on per-node `lan_guard`, not on a VLAN. |
| A.8.23 Web filtering | N/A | No browsing takes place on the platform. | None. |
| A.8.24 Use of cryptography | Practised | WireGuard for tailnet transport, Ansible Vault for repository secrets, Tailscale-issued certificates for HTTPS. | No key management procedure; SMB on the LAN is not covered by the overlay. |
| A.8.25 Secure development lifecycle | Partial | Conventional commits, pull requests, linting and the repository validator. | No threat modelling step. |
| A.8.26 Application security requirements | N/A | No applications are developed here. | None. |
| A.8.27 Secure architecture and engineering principles | Practised | Decisions with options and trade-offs in [`docs/decisions/`](../decisions/design-decisions.md). | Decisions are reviewed by their author only. |
| A.8.28 Secure coding | Partial | `ansible-lint` at a pinned version in CI ([`ansible-lint.yml`](../../.github/workflows/ansible-lint.yml)); `promtool` tests for alert rules in `docker/monitoring/prometheus/rules/tests/`. | Lint cannot see broken handler wiring, because handler names resolve at notify time. |
| A.8.29 Security testing in development and acceptance | Gap | `--check --diff` against production is the only pre-deployment test; Molecule is deferred. | Every change is tested by being applied. |
| A.8.30 Outsourced development | N/A | None. | None. |
| A.8.31 Separation of development, test and production | Partial | `preflight.yml` refuses any run from a control-node tree that is not a clean `main` in sync with `origin` (`ansible/playbooks/preflight.yml`). | There is no test estate. |
| A.8.32 Change management | Enforced | Changes reach `main` only by pull request with required checks ([`validate-repo.yml`](../../.github/workflows/validate-repo.yml)); the weekly drift sweep reports live changes that no commit explains. | A change made by hand on a node is found only by the next sweep. |
| A.8.33 Test information | Practised | Restore tests use real dumps in a throwaway instance on a separate port and remove it afterwards. | Test data is production data. |
| A.8.34 Protection during audit testing | Practised | Verification runs read-only or against throwaway copies, never against the live cluster. | Nothing enforces that a new check follows the same rule. |

## The gaps that matter, in order

Ordered by consequence. Each maps to an item in the [remediation plan](remediation-plan.md).

1. **No off-site copy** (A.8.13, A.5.30). A fire, a theft or ransomware reaching the SMB mounts
   decides the outcome.
2. **The escrow is unproven** (A.5.17). The vault password has no other copy, and the escrow has
   never been restored from.
3. **Secure disposal is undecided while a disk replacement is due** (A.7.14).
4. **Power quality is unverified** (A.7.11) and is the leading hypothesis for an open fault.
5. **The observer shares a failure domain with the observed** (A.8.16) until the external
   heartbeat is live.
6. **No separation of test and production** (A.8.29, A.8.31). Every change is tested by being
   applied.
7. **Logs have no tamper protection** (A.8.15).

## Review

Reviewed with the weekly fleet audit. A row changes in the same pull request as the work that
changes its status, and a remediation item that closes updates its row here.
