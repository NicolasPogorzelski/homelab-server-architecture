# Controls Built to Be Learned, Not Because the Platform Needs Them

## Status

Decided 2026-09-16. Four controls that the assessment of the same day argued against building at
this scale will be built anyway, for a stated reason that is not operational. The decision covers
how they are labelled and how they leave again, because the labelling is the part that is easy to
skip and expensive to skip.

## Context

A review on 2026-09-16 produced two lists. One was work the platform needs: the patch posture
nobody measures, a name-resolution responder on the control node, a database backup with no tested
restore, a binding decision that had not been executed. The other was a short list of controls the
review deliberately argued against - fleet-wide syscall auditing and file-integrity monitoring,
central log aggregation, high availability, and software bills of materials with signature
verification. The argument against each was the same shape: at ten guests and one operator they
produce output nobody reads, and this repository already records what an unread guard is worth.

The operator's goal for the second list is not operational. It is to have built the thing once,
seen what it emits, and be able to say what the same control looks like in an environment that has
a security team, a change process and an on-call rota. That is a legitimate goal and a different
one from hardening this platform, and the difference has to survive contact with a reader.

It has to survive it because this repository is public and is read by people assessing judgement.
A reviewer who finds `auditd` running on a ten-node homelab draws one of two conclusions: the
author does not know when a control is disproportionate, or the author knows exactly and said so.
Only the second is true here, and only writing it down makes it legible.

## Decision

Build all four, and mark each one as an exercise at every place a reader meets it.

**The marking is not a comment in a playbook.** It is a row in the remediation plan under a heading
that says what the section is, a paragraph in whatever service or platform document describes the
control, and - where the control produces a metric or a rule - a note next to it saying that
nothing is on call for it. A control that is indistinguishable from a needed one, six months later,
is a control that will be defended as needed.

**Nothing from this list enters `security-controls.md` as `Enforced`.** Check 32 requires an
Enforced row to cite its evidence, and the evidence available for these is that the unit is active.
That is evidence of running, not of the control being necessary here or of anyone reading its
output. They may appear as `Practised` with the exercise noted, or not appear at all.

**Alerting stays off for them unless the alert would have been built anyway.** An exercise that
pages is an exercise that trains the operator to ignore pages, which is the failure this platform
has already catalogued twice - `PostgreSQLBackupStale` blind during an outage, and the offsite
rules that fired for a machine that did not exist.

## What each one is here, and what it is in a job

The right-hand column is the point of the exercise. It is written from what the control is for,
not from a product catalogue, and it is deliberately the part this homelab cannot demonstrate.

| Control | What it is here | What it is where it belongs | What this setup cannot exercise |
|---|---|---|---|
| `auditd` plus a file-integrity check | Syscall rules on one or two nodes and a weekly `dpkg --verify` projection in `fleet_snapshot`; output read by the person who configured it | The evidence layer an investigation runs on: who touched what, from which session, in an append-only store the touched machine cannot rewrite | Nobody is adversarial here, nothing is retained off-box, and there is no investigator separate from the administrator |
| Central log aggregation | One collector shipping journals off the nodes into a single searchable place | Correlation across hosts and services, and retention that outlives the machine that produced the log - which is what makes it usable after a compromise | Ten nodes that reboot nightly and one reader; correlation has nothing to correlate |
| High availability | The mechanics made visible: what a quorum is, what fencing does, why a single node arms a watchdog against itself | Removing the human from the recovery path for services whose downtime costs more than the second machine | There is one machine. HA on one node is a demonstration, and a dangerous one to leave armed |
| SBOM and signature verification | Generating a bill of materials for the compose stacks and verifying what can be verified | Knowing within an hour whether a newly published CVE touches anything you run, and refusing images whose provenance cannot be shown | No procurement, no registry of record, and a fleet small enough to answer the same question by hand |

## Consequences

- The platform carries four controls whose cost is real and whose benefit here is knowledge. That
  cost is accepted with the reason stated, rather than discovered later as unexplained complexity.
- Every one of them adds surface: a daemon, a port, a log stream, a scheduled job. Each is subject
  to the same binding rule, the same drift sweep and the same review as anything else, and an
  exercise that violates the platform's own rules is worse than no exercise.
- The review that argued against them is not withdrawn. It stands, in this file, as the reason the
  work is labelled the way it is.

## Exit

Each control is revisited once the Terraform track has started, and gets one of two answers: kept,
with an operational justification written at that point, or removed. Not deciding is not one of the
answers. A platform that accumulates controls nobody can justify is the shape this repository
refuses elsewhere, and it would be a poor advertisement for the judgement the rest of it argues for.

The exercise block is also the condition that ends the maintenance mode: when these four and the
four operational findings from the same assessment are done, the Terraform track begins. That is
recorded in `CLAUDE.md`, which is where the learning track is steered from.

**Amended 2026-09-24.** An identity track now sits between this block and Terraform. It starts
before the sshd rollout has reached every node, and Terraform still waits for both, see
[the identity decision](identity-before-terraform.md).
