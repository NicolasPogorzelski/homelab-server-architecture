# The Tailnet Policy Is Applied From Git

## Status
Accepted 2026-11-17. Supersedes / superseded by: -.

## Context
The tailnet policy (tag owners, host aliases, rules, node attributes and the `tests` block) lives in
the Tailscale admin console. [`tailscale-acl.md`](../platform/tailscale-acl.md) mirrors it
sanitized, and a change is written there and then typed into the console by hand. The console
rejects a policy that breaks a test on save, but nothing compares the console with the mirror, and
a console edit goes through no review and leaves no record in this repository.

Tailscale applies a policy file from a repository with its GitHub Action
`tailscale/gitops-acl-action` ([documentation](https://tailscale.com/kb/1306/gitops-acls-github)):
the action runs the policy's tests on a pull request (`test`) and replaces the console's policy
after a merge (`apply`). It authenticates with an OAuth client, a federated identity (OIDC from the
GitHub Actions run, no stored secret), or an API key that expires after 90 days at most. The admin
console can be set to refuse edits; owners and admins can still override that refusal.

The raw policy file holds what the mirror leaves out: the real address behind each host alias and
the e-mail address of the external user's account in
[Rule 13](../platform/tailscale-acl.md#rule-13---external-user-through-machine-sharing). The
workflow adds the tailnet ID as an input. Tailscale's documentation advises a private repository
because policy files carry e-mail addresses.

## Options
- **Keep the console as the source.** Nothing to protect, but console and mirror can differ
  unnoticed, and nobody reviews a policy change.
- **The raw file in this public repository, applied by the action.** One file instead of two, but
  it publishes the tailnet ID, an external user's e-mail address and every node address, which the
  [sanitization rule](../CONVENTIONS.md#sanitization) forbids.
- **A private repository holding the policy, applied by the action, with the sanitized mirror kept
  here.** Chosen.

## Decision
A private repository holds `policy.hujson` with its `tests` block and one workflow: `test` on every
pull request, `apply` on a push to `main`. The action authenticates by federated identity with the
`policy_file` scope, and is pinned by commit SHA like every other action here. The console is set to
refuse edits; an override there is a break-glass step, and the next `apply` replaces it.
`tailscale-acl.md` stays the public description, and a check in the private repository fails when
its rules (source, destination, port) differ from the sanitized blocks in that document.

## Consequences
- Whoever can merge to `main` of the private repository rewrites the tailnet policy. That
  repository needs the same `main` protection as this one, and the GitHub account becomes part of
  the tailnet's trust boundary.
- A federated identity needs no secret rotation. If it cannot be set up, an OAuth client secret
  takes its place as a repository secret; an API key is ruled out by its 90-day expiry.
- An emergency change in the console is overwritten by the next `apply` unless the same change is
  merged into the private repository afterwards.
- The comparison check is new code. Until it exists, the mirror is compared by hand, as now.
- Tailscale's policy history in the console stays the second record of every change.
- The [Headscale migration](headscale-migration.md) replaces the step that applies the policy.
  Whether Headscale accepts the same file and its `tests` block is checked when that track starts.
- After the first `apply`, the "Source of truth" paragraph of `tailscale-acl.md` names the private
  repository.

## Related Documents
- [Tailscale ACL & tagging model](../platform/tailscale-acl.md)
- [Headscale migration](headscale-migration.md)
- [Identity before Terraform](identity-before-terraform.md)
