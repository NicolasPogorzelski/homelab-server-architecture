---
name: start-scan
description: Full scan of this repository and the live fleet from four seats (IT security, OT security, DevSecOps, DevOps), followed by a to-do list of findings, recommendations and "also advisable". Started only by hand, with /start-scan.
disable-model-invocation: true
---

# Start scan

A routine a person starts with `/start-scan`, usually at the beginning of a working session,
so the assignment does not have to be restated each time.

## Assignment

Pick up where the last work stopped. Scan the whole repository and the live fleet from four
seats - **IT security, OT security, DevSecOps, DevOps** - completely, not by sample. Then write
a to-do list in this order:

1. **Known open items** (handover, remediation plan, known errors, open points from memory).
2. **Findings of the four seats**, grouped as:
   - **Adjustments** - best practices not met
   - **Errors** - in configuration and in the documentation
   - **Missing information** - gaps in the repository and in the live configuration
3. **Also advisable** - suggestions that widen the view: established technologies, practice in
   a company setting, developing trends. IT security has the highest priority here. Examples
   from the first run: OIDC, Tailnet Lock, SLSA/Sigstore, passkeys, policy as code.

## Procedure

1. Read the newest `.claude/handover-*.md`, `git status` / `git log`, `./scripts/validate-repo.sh`.
2. Live, read-only (every write is a person's step):
   - Host: `ssh server` - shutdown/wake schedule, failed units, timers, listeners, SMART
     (by-id), KE-14 kernel messages, thin pool, Postfix queue, `sshd -T`, root
     `authorized_keys`, pending apt, Tailscale version and Tailnet Lock.
   - Guests: through lxc250 (`ssh devops`, `export PATH=$HOME/.local/bin:$PATH`, `cd
     ~/git/homelab-server-architecture/ansible`), one read script via `ansible guests -b -m
     script` - OS, failed units, listeners, `sshd -T`, pending apt and security updates, Docker
     images and ports, `authorized_keys`, NOPASSWD sudo, Tailscale version.
   - Prometheus on lxc200 (`ansible lxc200 -m script -a "executable=/usr/bin/python3 ..."`):
     alerts, targets, SMART history, backup, restore, drift and offsite metrics.
   - Drift report `/var/lib/fleet-drift/report.txt` on lxc250.
3. Repository: remediation plan, known-error status, `security-controls.md`, and the
   present-tense claims of the node, service and platform documents against the measurement
   (agent `state-claims`); writing against `docs/CONVENTIONS.md` (agent `prose-tics`); compose
   stacks, workflows, role defaults. CLAUDE.md holds no facts and is not checked against the
   measurement.
4. Back every statement with a measurement. Report "measured and clean" apart from "could not be
   measured". Say plainly what was not read.

## Form

German in the chat; repository content stays English. Never print Tailscale IPs or the tailnet
ID. No change to the fleet without explicit approval; dry runs are run by the assistant itself.
