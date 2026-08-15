# Security Policy

## What this repository is

This repository documents a private, single-host Proxmox platform. It contains architecture
documentation, runbooks, Ansible roles, Docker Compose files and helper scripts — no application
code, and no software product that anybody installs.

The platform itself is not reachable from the internet: no public ingress, no port forwarding,
access exclusively over a Tailscale overlay network. There is therefore nothing here that can be
attacked remotely by reading this repository.

## What a finding looks like here

Because there is no exposed service, the realistic risk is **disclosure, not exploitation** —
something published in this repository that should have been sanitized first. Concretely:

- A real Tailscale address or tailnet identifier where a placeholder belongs
- A real LAN address, hardware serial, disk label or hostname that identifies physical equipment
- A credential, token, private key or `.env` file — in the working tree **or anywhere in the git
  history**
- A snippet, unit file or Ansible task that would weaken the system of a reader who copied it as
  written

The last category matters as much as the first three. This repository is a learning artifact and
is read as an example, so a plausible-looking but unsafe configuration is a real defect even
though it exposes nothing of mine.

## How to report

Email **funandspam@proton.me** with `SECURITY` in the subject line.

**Please do not open a public issue for a disclosure finding.** An issue describing a leaked value
republishes that value in a more visible place than it was already, and it notifies everyone
watching the repository before it can be rotated. For anything that is not a disclosure — an
inaccuracy, a broken procedure, a dangerous example — a normal issue is welcome and preferred.

## What to expect

Acknowledgement within seven days. This is a personal project maintained alongside full-time
commitments, so there is no service level beyond that, and no bounty.

When a report concerns a leaked secret, the response order is fixed:

1. **Rotate the value first.** Anything pushed to a public repository must be treated as
   compromised from the moment it was pushed, regardless of how quickly it is removed. Deleting
   the file changes nothing about that.
2. Remove the content from the current tree and correct whatever process allowed it through.
3. Only then consider the history. Rewriting published history is a deliberate decision with its
   own costs, and in this repository it may be decided against — which is acceptable precisely
   because step 1 has already made the exposed value worthless.

## Out of scope

- The private platform itself, its live hosts and its network — they are not accessible to you and
  are not part of this repository.
- Vulnerabilities in the upstream projects deployed here (Nextcloud, Paperless-ngx, Vaultwarden and
  the rest). Report those to their maintainers.
- Known weaknesses that are already documented as such in
  [`docs/platform/known-errors.md`](../docs/platform/known-errors.md) and
  [`docs/platform/remediation-plan.md`](../docs/platform/remediation-plan.md). These are tracked
  accepted risks, not undiscovered ones. A report that one of them is worse than assessed is very
  much in scope.

## Automated safeguards

Publication is gated by [`scripts/validate-repo.sh`](../scripts/validate-repo.sh), which runs
locally before every commit and again in CI on every push and pull request. Among its checks:
committed `.env` files, private keys and certificates, unsanitized Tailscale addresses, tailnet
identifiers, LAN addresses, size-encoding disk labels, and tracked private legend files.
GitHub secret scanning with push protection is enabled on top of it.

These are pattern matches against the working tree. They cannot recognize a secret that does not
look like one, and they do not scan history. They lower the probability of a leak; they do not
remove the need for this policy.
