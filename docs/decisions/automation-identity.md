# Automated Sessions Use Their Own Key Through the Control Node

## Status
Accepted 2026-11-17. Supersedes / superseded by: -.

## Context
Automated sessions on the admin workstation use the person's SSH key: root on the hypervisor,
`devops` on lxc250, and the break-glass accounts `storage` on vm102 and `gpu` on vm100, whose keys
`breakglass` enforces. The key has no passphrase and is held in the desktop's ssh-agent, so any
process under the workstation account can use it without a prompt.

Verified 2026-11-17: 37 root logins on the hypervisor that day with that key, all from one
automated session, by `journalctl -u ssh` on the hypervisor.

Verified 2026-11-17: two bursts of non-interactive `storage` logins on vm102 with `sudo` probes,
by `journalctl -u ssh` and `journalctl _COMM=sudo` on vm102.

The logs cannot tell these logins from the person's, and revoking the key for automation would
revoke the emergency access with it. Automated sessions run under the person's Unix account and can
read every file the person can.

## Options
- **Keep one key.** No work, but no attribution, no separate revocation, and an injected command
  in a session holds root on the hypervisor.
- **A second key with the same reach as the person's.** Attribution in the logs, but the same
  reach, and the person's key stays open to the session.
- **A second key for the control node only, with the person's key behind a passphrase.**

## Decision
Automated sessions use `~/.ssh/id_ed25519_agent`, which `agent_access` installs for `devops` on
lxc250, accepted only from the workstation's Tailscale address (`from=`) and with `restrict`. They
reach the guests and the hypervisor only through Ansible from there, including read-only checks.
The person's key keeps its reach and gets a passphrase; automated sessions connect through an SSH
alias that names their own key with `IdentitiesOnly`.

## Consequences
- Every automated login shows the agent key's fingerprint in lxc250's sshd log, and removing one
  line in `host_vars/lxc250.yml` revokes it without touching break-glass access.
- Through `devops` and Ansible, automated sessions can still change any node: `ansible` has
  passwordless sudo. Read-only automation needs an Ansible identity without sudo, which is not
  built.
- A passphrase stored in the desktop keyring with automatic unlock would undo the separation.
- Host checks that used direct root SSH run as ad-hoc Ansible against the `proxmox` group.
