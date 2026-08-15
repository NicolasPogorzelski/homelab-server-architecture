# Security Controls — ISO/IEC 27001 Annex A Mapping

Mapped 2026-08-15 against ISO/IEC 27001:2022 Annex A, as elaborated in ISO/IEC 27002:2022.

## What this document claims, and what it does not

**It does not claim compliance, and it never will.** The certifiable part of ISO/IEC 27001 is
clauses 4–10 — the management system: a defined scope, a documented risk assessment with an
accountable owner, a Statement of Applicability, an internal audit programme, and a management
review. Annex A is only the control catalogue those clauses draw from. A platform run by one person
in a flat has no management to review anything and no independent auditor, so "ISO 27001 compliant"
would be a false statement, and a mapping that pretended otherwise would be worth nothing.

What this document does claim is narrower and more useful: **it separates the controls that are
enforced from the practices that merely happen to be followed.** That distinction was the reason
for the exercise. A practice that depends on the operator remembering it is not a control — it is an
intention, and intentions do not survive illness, a rebuild, or a busy month. Half of what looked
solid before this mapping turned out to be intention.

The mapping also produced a second result worth stating plainly: this platform already implemented a
significant part of Annex A before anyone opened the standard, under different names.
[`known-errors.md`](known-errors.md) is a corrective-action log, [`remediation-plan.md`](remediation-plan.md)
is a risk treatment plan, [`changelog.md`](changelog.md) holds change records with verification
evidence, and the [runbooks](../../runbooks/README.md) are documented operating procedures. The gap
was vocabulary, not substance — except where it was substance, and those cases are listed at the
end.

## How to read the status column

| Status | Meaning |
|---|---|
| **Enforced** | A machine refuses the wrong outcome. Skipping it requires deliberately disabling something, and that act leaves a trace. |
| **Practised** | Done consistently and documented, but nothing prevents an exception. Depends on the operator. |
| **Partial** | Implemented for part of the estate, or implemented but with a known blind spot. |
| **Gap** | Not implemented. Listed with its consequence, not excused. |
| **N/A** | Not applicable, with the reason. An unjustified "not applicable" is how control catalogues become decoration. |

## Organizational controls (A.5)

| Control | Status | Evidence and notes |
|---|---|---|
| A.5.1 Policies for information security | Partial | Rules exist and are binding — the Tailscale binding rule, "every scheduled job is a timer with `Persistent=true`", the sanitization rules — but they are distributed across `CLAUDE.md` and the platform docs rather than stated as policy. This file is the closest thing to a consolidated statement. |
| A.5.2 Roles and responsibilities | N/A | One operator holds every role. Recorded rather than hidden: the bus factor is 1, and the compensating measure is documentation depth sufficient for a stranger to take over. |
| A.5.3 Segregation of duties | N/A | Structurally impossible with one person. Partial compensation: the pull-request flow forces the author to re-read their own change in a diff view before it can reach `main`. |
| A.5.7 Threat intelligence | Partial | No structured intelligence source. Advisory-driven Dependabot security updates and the weekly [image scan](../../.github/workflows/image-scan.yml) now provide the narrow, relevant slice. |
| A.5.9 Inventory of assets | Practised | One document per node under [`docs/nodes/`](../nodes/), plus the Ansible inventory. **Known defect:** lxc250 appears in no inventory group, so an asset that holds the deployment credentials sits outside the system that manages the estate — see [lxc250 § Open Items](../nodes/lxc250.md). |
| A.5.12 Classification of information | Partial | Introduced 2026-08-15 in [`data-classification.md`](data-classification.md). Until then everything from tax documents to media files was handled identically. |
| A.5.13 Labelling of information | N/A | Deliberate. Labelling pays off where many people handle data they did not create. Here it would be ceremony; the classification table carries the same information at the cost of one lookup. |
| A.5.14 Information transfer | Enforced | All inter-node traffic runs over the Tailscale overlay (WireGuard). SMB is reachable on the LAN only from vm100 and the hypervisor, enforced by the `smb_guard` nftables table on vm102 — see [`samba.md`](samba.md). |
| A.5.15 Access control | Enforced | Tier model with explicit ACL rules per tag, [`tailscale-acl.md`](tailscale-acl.md). **Caveat worth naming:** that document *mirrors* the policy; the authoritative copy lives in the Tailscale admin console, so the two can drift. |
| A.5.16 Identity management | Practised | Per-node service accounts, a dedicated `ansible` user distinct from the interactive admin account. |
| A.5.17 Authentication information | Partial | Ansible Vault for secrets in the repository. The vault password itself exists in exactly one copy on a disk with unresolved I/O faults — the single largest irreversible-loss risk on the platform, tracked as Tier 1 #1 in the [remediation plan](remediation-plan.md). |
| A.5.18 Access rights | Enforced | The `breakglass` role manages `authorized_keys` with `exclusive: true`, making the inventory the sole source of truth. **Revocation, not just granting** — the change that removed two stale keys nobody had noticed. |
| A.5.19–A.5.22 Supplier relationships | N/A | No suppliers, no contracts, no outsourced processing. |
| A.5.21 ICT supply chain | Partial | Container images pinned to exact versions, GitHub Actions pinned to commit SHAs rather than mutable tags (2026-08-15). Not covered: image provenance and signature verification. |
| A.5.23 Security for cloud services | N/A | No cloud services in the platform path. Revisit when the Terraform track introduces AWS. |
| A.5.24 Incident management planning | Practised | [Runbooks](../../runbooks/README.md) per failure class, plus the known-error register. |
| A.5.25 Assessment and decision on events | Practised | Every known error carries a root-cause section and a decision — fix, accept, or defer with a stated reason. |
| A.5.26 Response to incidents | Practised | Procedures exist for the failure classes that have actually occurred. Untested for classes that have not. |
| A.5.27 Learning from incidents | Practised | Distinctive here: entries record the *class*, not only the fix. "Ordering is not readiness" (KE-18) and "when closing a configuration error, sweep the other nodes" (KE-6) are generalizations that later prevented separate incidents. Post-mortems in [`incidents/`](incidents/). |
| A.5.28 Collection of evidence | Practised | The changelog records measured values — timer timestamps, row counts, metric deltas — rather than assertions that something worked. |
| A.5.29 Security during disruption | Partial | Recovery procedures exist. No exercise has ever simulated the loss of the whole host. |
| A.5.30 ICT readiness for continuity | Partial | A full-cluster PostgreSQL restore into a throwaway instance runs monthly and is alerted on when stale ([`pg-restore.md`](../../runbooks/database/pg-restore.md)). This is above the industry norm. What is missing: recovery objectives to measure it against, now stated in [`data-classification.md`](data-classification.md), and any tested recovery path for anything other than the database. |
| A.5.31 Legal and regulatory requirements | Partial | Licence terms stated ([`LICENSE`](../../LICENSE), 2026-08-15). Data protection assessed in [`data-classification.md`](data-classification.md). |
| A.5.33 Protection of records | Enforced | Change records live in git. Since 2026-08-15 commits are signed with an SSH key, so authorship is cryptographically verifiable rather than a free-text field, and `main` cannot be force-pushed or deleted. |
| A.5.34 Privacy and PII | Partial | Assessed 2026-08-15 for the first time; see [`data-classification.md`](data-classification.md). Previously not considered at all, despite the platform holding identity documents and serving two household members outside the operator. |
| A.5.35 Independent review | Gap | Structurally unavailable. Partial compensation: the weekly fleet audit is a self-review against the documentation, and it has repeatedly found live faults — which is evidence that it is a real check and not a formality. |
| A.5.36 Compliance with policies | Enforced | [`validate-repo.sh`](../../scripts/validate-repo.sh), 18 checks, run by a pre-commit hook locally and by CI on every push and pull request. |
| A.5.37 Documented operating procedures | Enforced | Every runbook must contain `Precondition`, `Verification` and `Failure`; Check 5 fails the build otherwise. A procedure without a verification step is rejected mechanically. |

## People controls (A.6)

| Control | Status | Evidence and notes |
|---|---|---|
| A.6.1–A.6.6 Screening, terms, disciplinary, responsibilities after termination | N/A | No employment relationship exists. |
| A.6.3 Awareness and training | N/A | The operator is the sole user. The learning-mode discipline in `CLAUDE.md` — explain every flag, root cause before fix — is the functional analogue. |
| A.6.7 Remote working | Practised | All administration happens remotely over Tailscale with key-only SSH; password authentication is disabled fleet-wide. This is the normal operating mode, not an exception. |
| A.6.8 Reporting information security events | Practised | Reporting channel published in [`SECURITY.md`](../../.github/SECURITY.md), 2026-08-15, with an explicit instruction not to report a disclosure through a public issue. |

## Physical and environmental controls (A.7)

The weakest family, and the one most easily overlooked by someone who thinks about infrastructure
primarily as software.

| Control | Status | Evidence and notes |
|---|---|---|
| A.7.1–A.7.4 Perimeters, entry, securing offices, monitoring | Gap | Undocumented. The platform occupies a private flat; who has physical access, and what that implies for full-disk encryption and console access, has never been written down. |
| A.7.10 Storage media | Gap | No media handling procedure. The pending secrets escrow (Tier 1 #1) is the first item that forces one to exist. |
| A.7.11 Supporting utilities | Gap, and live | The leading hypothesis for [KE-14](known-errors.md#ke-14) — recurring I/O errors on the disk carrying every guest root filesystem — is a sagging 12 V rail. Power quality is an unverified suspicion in an open incident, and no uninterruptible supply is documented. |
| A.7.13 Equipment maintenance | Partial | SnapRAID scrub and sync run on timers with runbooks. SMART data is collected but, as measured, does not export the attributes that would have caught the failing disk — see [`operations.md`](operations.md). |
| A.7.14 Secure disposal or re-use | Gap, and imminent | The aux-disk is scheduled for replacement and carries application data including personal documents. Nothing currently specifies that it must be erased before it leaves the flat, and its 7680 unreadable sectors mean a software overwrite cannot be assumed to have covered every block. Added to the [remediation plan](remediation-plan.md). |

## Technological controls (A.8)

| Control | Status | Evidence and notes |
|---|---|---|
| A.8.1 User endpoint devices | Partial | The admin workstation runs an immutable, image-based OS. Endpoint hardening is otherwise undocumented. |
| A.8.2 Privileged access rights | Practised | `PermitRootLogin no` fleet-wide; the automation account is separate from the interactive one; break-glass keys are declared in the inventory. |
| A.8.3 Information access restriction | Enforced | Tier tags decide which node may reach which port; the default is deny. |
| A.8.4 Access to source code | Enforced | Since 2026-08-15: `main` requires a pull request, blocks force-pushes and deletion, and requires both CI checks to pass. No bypass actors are configured, including for the owner. |
| A.8.5 Secure authentication | Enforced | `PasswordAuthentication no` deployed by role, so the setting is restored on every run rather than surviving as a manual edit. |
| A.8.6 Capacity management | Enforced | Thin-pool metrics with warning, critical and metadata thresholds, plus an absolute-bytes alert for the archive pool — percentage being the wrong measure for a multi-terabyte array. See [`monitoring.md`](monitoring.md). |
| A.8.7 Protection against malware | N/A | Deliberate. On a Linux fleet with no interactive users and no public ingress, a scanner would add attack surface and a false sense of coverage. The real measures are pinned images, least privilege and network isolation. |
| A.8.8 Management of technical vulnerabilities | Partial | Unattended upgrades restricted to security pockets with kernel and driver packages blacklisted, so an unattended reboot cannot break GPU passthrough. Container images are pinned **and frozen** while the aux-disk hold is in force; the weekly Trivy scan makes that accepted risk measurable instead of invisible. |
| A.8.9 Configuration management | Partial | Everything guest-side is Ansible-managed. The hypervisor and the control node are not, so a rebuild of either loses hand-deployed units — the single most-cited prerequisite in the remediation plan. |
| A.8.10 Information deletion | Gap | No retention or deletion policy for anything. Relevant to A.7.14 and to the documents in Paperless. |
| A.8.11 Data masking | N/A | No shared or exported datasets. |
| A.8.12 Data leakage prevention | Enforced | Seven of the eighteen repository checks exist solely to stop identifying information reaching a public repository, backed by GitHub secret scanning with push protection. Honest limit, stated in [`SECURITY.md`](../../.github/SECURITY.md): pattern matching against the working tree, blind to history and to secrets that do not look like secrets. |
| A.8.13 Information backup | Partial | Dumps are verified at write time against three failure modes before the file is given its real name, and a monthly restore test proves they are usable. **The gap is categorical, not incremental: every copy is on the same site.** Tier 1 #3. |
| A.8.14 Redundancy | N/A | Deliberate architectural choice: single host, no high availability, recovery-oriented design. SnapRAID parity protects media against disk loss; it is not redundancy of processing and is not treated as such. |
| A.8.15 Logging | Partial | journald is persistent on both VMs with months of boots retained. Weaknesses: `Storage=` is unset, so persistence is a property of a directory that happens to exist rather than of the configuration; no retention limit is pinned; there is no central aggregation and no tamper protection. |
| A.8.16 Monitoring activities | Enforced | Node, service and unit-level alerting, including alerts for the *absence* of expected signals. **Known structural blind spot:** the monitoring stack runs on the host it monitors, so a total outage produces silence rather than an alert — the reason an external heartbeat sits on the backlog. |
| A.8.17 Clock synchronization | Enforced | `chrony` role. Without it, correlating logs across ten nodes during an incident is guesswork. |
| A.8.18 Use of privileged utility programs | Partial | Maintenance scripts are deployed by roles into `/usr/local/sbin` with root ownership. No formal restriction beyond file permissions. |
| A.8.19 Software on operational systems | Partial | Package installation is role-driven; container images are pinned. Ad-hoc installation is possible and has happened — the hand-deployed exporters are the evidence. |
| A.8.20 Networks security | Enforced | No public ingress, no port forwarding, LAN treated as untrusted. |
| A.8.21 Security of network services | Enforced | Services bind the overlay address or loopback; binding to a LAN interface is a documented violation. Three such violations have been found and fixed by measurement; two remain open with their own design decisions pending. |
| A.8.22 Segregation of networks | Enforced | Tier model, deny by default, per-tag rules. |
| A.8.23 Web filtering | N/A | No user browsing takes place on the platform. |
| A.8.24 Use of cryptography | Practised | WireGuard for all transport, Ansible Vault at rest for repository secrets, ACME certificates for the one service that terminates TLS itself. No key management procedure beyond that — see A.5.17. |
| A.8.25 Secure development lifecycle | Partial | Conventional commits, pull requests, linting, a repository validator. No threat modelling step. |
| A.8.26 Application security requirements | N/A | No applications are developed here. |
| A.8.27 Secure architecture and engineering principles | Practised | Architecture decisions are written down with the alternatives and the trade-off, in [`docs/decisions/`](../decisions/design-decisions.md). Rejected options are recorded with their reasons, which is what makes them reviewable later. |
| A.8.28 Secure coding | Partial | `ansible-lint` at a pinned version, locally and in CI. Documented limit: lint cannot see broken handler wiring, because handler names resolve at notify time. |
| A.8.29 Security testing in development and acceptance | Gap | `--check --diff` against production is the only pre-deployment test. Molecule is deferred; there is no acceptance environment. |
| A.8.30 Outsourced development | N/A | None. |
| A.8.31 Separation of development, test and production | Gap | The control node deploys from a working tree, not from a commit, and there is no test estate. A node on a feature branch would silently run code matching no commit — this has occurred. |
| A.8.32 Change management | Enforced | Since 2026-08-15. Previously practised only: the pull-request discipline was real but unenforced, and `main` accepted direct pushes. |
| A.8.33 Test information | Practised | The monthly restore test uses real dump data, restores it into a throwaway cluster on a separate port with manual start configuration, and removes it afterwards — verified to leave no remnants and never to touch the live cluster. |
| A.8.34 Protection during audit testing | Practised | The same design principle: verification must not be able to damage what it verifies. |

## The gaps that matter, in order

Ordered by consequence, not by effort. Each is tracked in the [remediation plan](remediation-plan.md);
this list exists so the ISO reading of them is on record.

1. **No off-site copy of anything** (A.8.13). Every other backup property is now good, which makes
   this the one that decides the outcome of a fire, a theft or ransomware reaching the SMB mounts.
2. **One copy of the vault password** (A.5.17), on a disk with unresolved I/O faults. Loss is
   unrecoverable by construction — no restore path exists, because the restore path is encrypted
   with the thing that was lost.
3. **Physical and environmental controls are undocumented** (A.7). One of them is an open incident:
   the leading hypothesis for KE-14 is power quality.
4. **Secure disposal is unspecified while a disk replacement is scheduled** (A.7.14). This one has a
   deadline set by hardware delivery, not by choice.
5. **No separation of development and production** (A.8.31), and **no security testing before
   deployment** (A.8.29). Together these mean every change is tested by being applied.
6. **The observer shares a failure domain with the observed** (A.8.16). Measured, not theorised: a
   62-hour outage produced no alert because the alerting stack was inside the outage.
7. **Logging has no defined retention and no tamper protection** (A.8.15). Records that can be
   silently rewritten are weak evidence.
8. **Two nodes have no failed-unit alerting** and **two nodes are outside configuration management**
   (A.8.9). The overlap between those sets is lxc250, which holds the deployment credentials.

## What the mapping itself changed

Done on 2026-08-15, in the same pass that produced this document:

- Branch ruleset on `main`: pull request required, force-push and deletion blocked, both CI checks
  required, no bypass actors. Turned A.8.4 and A.8.32 from practice into enforcement.
- SSH commit signing enabled, so the authorship of every change record is verifiable (A.5.33).
- [`SECURITY.md`](../../.github/SECURITY.md) with a reporting channel and a stated response order
  that puts rotation before removal (A.6.8).
- [`LICENSE`](../../LICENSE) — terms of use stated rather than absent (A.5.31).
- GitHub Actions pinned to commit SHAs; advisory-driven security updates enabled (A.5.21, A.8.8).
- Weekly Trivy scan of every pinned image, publishing to the Security tab, so the standing update
  hold is a monitored acceptance rather than an unexamined one (A.8.8).
- [`data-classification.md`](data-classification.md): the first classification of the data on this
  platform, with recovery objectives and a data-protection assessment (A.5.12, A.5.30, A.5.34).

## Review cadence

Reviewed with the weekly fleet audit, and rewritten whenever a control moves between states. The
status column is the part that rots: a control that was enforced stops being enforced the moment
someone adds a bypass, and nothing announces that. When a remediation item closes, the matching row
changes here in the same commit — the same rule the remediation plan already carries.

An entry that has been "Practised" for a year without becoming "Enforced" should be read as a
prediction that it will eventually be skipped.
