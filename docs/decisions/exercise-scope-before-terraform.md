# Four Controls Are Built as Exercises, and Labelled as Such

## Status
Implemented 2026-10-12. Decided 2026-09-16. Supersedes / superseded by: -.

Applied: `auditd` on the hypervisor, central journal collection on lxc200 from lxc211 and lxc260,
the `dpkg --verify` projection in `fleet_snapshot`, and the SBOM workflow
(`.github/workflows/sbom.yml`). High availability stays at reading
([ha-mechanics.md](../platform/ha-mechanics.md)). The next step toward Terraform is the
[identity track](../platform/remediation-plan.md#identity-track).

## Context
The 2026-09-16 assessment produced two lists. One was work the platform needs. The other named
controls it argued against at this scale: syscall auditing with file-integrity checks, central log
aggregation, high availability, and SBOMs with signature verification. At ten nodes that power
down nightly, each produces output nobody reads.

They are built anyway, to have run each control once, seen what it emits, and be able to say what
it looks like where a security team, a change process and an on-call rota exist. That goal is
legitimate but not operational, and a control that is indistinguishable from a needed one is later
defended as needed.

## Options
- **Skip them.** Lost: the learning goal is not met.
- **Build them like any other control.** Lost: they would read as necessary and accumulate.
- **Build them, and label each as an exercise everywhere a reader meets it.** Chosen.

## Decision
- Each control has a row in the remediation plan's exercise section and a paragraph in the
  document that describes it; where it produces a metric or rule, a note says nothing is on call
  for it.
- None enters `docs/platform/security-controls.md` as `Enforced`: a running unit proves the control
  runs, not that it is needed or read. It may appear as `Practised`, or not at all.
- No alerting for them unless the alert would exist anyway. An exercise that pages trains its
  recipient to ignore pages.

| Control | Here | Where it belongs | What this setup cannot exercise |
|---|---|---|---|
| `auditd` plus file-integrity check | Syscall rules on one node, a weekly `dpkg --verify` projection in `fleet_snapshot` | The evidence layer of an investigation, in an append-only store the touched machine cannot rewrite | No adversary, no off-box retention, no investigator separate from the administrator |
| Central log aggregation | One collector receiving journals from opted-in nodes | Cross-host correlation and retention that outlives the machine that produced the log | Few nodes, nightly reboots, one reader |
| High availability | The mechanics read and written down: quorum, fencing, why a single node arms a watchdog against itself | Removing the human from recovery where downtime costs more than a second machine | One machine; HA on one node is a demonstration, and dangerous to leave armed |
| SBOM and signature verification | A bill of materials for the compose images, signatures verified where published | Knowing within an hour whether a new CVE touches anything running; refusing images without provenance | No procurement, no registry of record, a fleet small enough to answer by hand |

## Consequences
- Four controls cost maintenance whose benefit here is knowledge; the cost is stated, not
  discovered later.
- Each adds surface (a daemon, a port, a log stream, a job) and is subject to the same binding
  rule, drift sweep and review as everything else.
- Exit: each control is revisited once the Terraform track starts and is either kept with an
  operational justification written then, or removed. The Terraform track also waits for the
  [identity track](identity-before-terraform.md).
