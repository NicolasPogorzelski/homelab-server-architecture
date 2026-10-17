# Security Policy

This repository documents a private, single-host Proxmox platform: documentation, runbooks, Ansible
roles, Docker Compose files and helper scripts. It ships no software product. The platform has no
public ingress; access is over a Tailscale overlay network only.

## What to report

The realistic risk is disclosure: something published here that should have been sanitized.

- A real Tailscale address or tailnet name where a placeholder belongs
- A real LAN address, hardware serial, disk label or hostname that identifies equipment
- A credential, token, private key or `.env` file, in the working tree or in the git history
- A snippet, unit file or Ansible task that would weaken a system if copied as written

## How to report

Email nicolas.pogorzelski@proton.me with `SECURITY` in the subject line. Do not open a public issue
for a disclosure finding: it republishes the value before it can be rotated. Inaccuracies, broken
procedures and unsafe examples that disclose nothing are welcome as normal issues.

Acknowledgement within seven days. There is no further service level and no bounty.

A leaked secret is handled in this order:

1. Rotate the value. Anything pushed to a public repository is compromised from that moment.
2. Remove it from the current tree and fix the check that let it through.
3. Decide whether to rewrite history. Step 1 has already made the value worthless.

## Scope

In scope: the content of this repository and its history, including reports that a weakness
documented in [`docs/platform/known-errors.md`](../docs/platform/known-errors.md) or
[`docs/platform/remediation-plan.md`](../docs/platform/remediation-plan.md) is worse than assessed.

Out of scope:

- The live platform, its hosts and its network.
- Vulnerabilities in upstream projects deployed here (Nextcloud, Paperless-ngx and the rest).
  Report those to their maintainers.
- Weaknesses already documented in the two files above.

## Automated safeguards

- [`scripts/validate-repo.sh`](../scripts/validate-repo.sh) runs in CI on every push to `main` and
  every pull request. It rejects committed `.env` files, private keys and certificates,
  unsanitized Tailscale and LAN addresses, tailnet names, size-encoding disk labels and tracked
  private legend files. These are pattern matches against the working tree.
- [`.github/workflows/secret-scan.yml`](workflows/secret-scan.yml) runs gitleaks over the full
  history on the same triggers.
- GitHub secret scanning with push protection is enabled.

None of these recognizes a secret that does not look like one.
