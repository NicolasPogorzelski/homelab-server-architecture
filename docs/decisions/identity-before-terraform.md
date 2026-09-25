# Decision: An Identity Track Between the Block and Terraform

## Status

Decided 2026-09-24. Scheduled for 2026-09-25 to 2026-09-27, one weekend, with a stated cut if it
does not fit. It amends the start condition of the Terraform track recorded in
[the exercise-scope decision](exercise-scope-before-terraform.md): the track now begins when the
block is done and this one is closed.

## Context

Every service on this platform keeps its own accounts. Access to the network is identity-based -
the Tailscale ACL decides which device may reach which node - but once a request arrives, each
application asks for its own password against its own user table. Measured 2026-09-24:

| Where | What holds identities |
|---|---|
| Nextcloud 31.0.12 | Local accounts for the household plus `admin`. `user_ldap` 1.22.0 is installed and disabled |
| Proxmox VE 9.1.4 | Realms `pam` and `pve`, one user, `root@pam` |
| Paperless-ngx 2.20.15, OpenWebUI 0.9.6, Grafana 13.0.2 | Local accounts each |
| Jellyfin 10.11.11, Audiobookshelf 2.35.1, Calibre-Web 0.6.26 | Local accounts each |

There is no directory and no identity provider. Adding a person means seven account creations,
removing one means remembering all seven.

The operator built an LDAP directory with `lldap` in a separate assessment project the week
before, with three applications binding against it. What that project did not build is OIDC: it
stopped at LDAP and described an OIDC provider only as its target architecture. Rebuilding the known
half in a second environment and adding the missing half is the learning goal here. The operational
goal - one place to add and remove a person - is real but small at this user count, and is not the
reason for doing it now.

Two findings from the same day bound the design.

**No reverse proxy.** Every service is published by `tailscale serve` on its own node. An identity
provider can still be used without one, because OIDC is a redirect between the browser, the
application and the provider. What is ruled out is the other pattern, a proxy that checks a session
before any request reaches the application. That pattern stays out of scope.

**`ts.net` is on the Public Suffix List.** Measured from `publicsuffix.org`: the Tailscale block
carries `ts.net` as a single entry. Authelia refuses a session cookie domain that exactly matches a
public suffix and requires the cookie domain to equal or contain the host name of its own portal
([session configuration](https://www.authelia.com/configuration/session/introduction/)). The widest
cookie possible is therefore `<tailnet-id>.ts.net`, which every node on the tailnet would receive.
The cookie is scoped to the provider's own `<node>.<tailnet-id>.ts.net` name instead: OIDC needs no
more, and nothing else on the tailnet has a use for it.

## Decision

Build one new node carrying an LDAP directory and an OIDC provider, and connect the applications
that support either, in an order that puts the lowest-risk client first.

**Components.** [`lldap`](https://github.com/lldap/lldap) as the directory, since its upstream
README names Authelia and Keycloak as the components to add for OAuth and OpenID and keeps itself
to LDAP. [Authelia](https://www.authelia.com/) as the OIDC provider, reading users from `lldap`.
Keycloak and Authentik were not chosen on footprint: the host has about 7 GB of memory available
and the thin pool 13 GB free, and a provider that runs on a machine that powers down nightly gains
nothing from the features that justify their size. Versions are pinned at build time; the current
releases on 2026-09-24 are Authelia v4.39.28 and lldap v0.6.3.

**Storage on lxc260.** Both support PostgreSQL. Their databases go on the platform database through
the `postgresql_provisioning` role, so the nightly `pg_dumpall` and the monthly restore test cover
them from the first night, instead of a second SQLite file with its own backup story. Authelia's
`encryption_key` is required and goes into the vault, and it is part of what the escrow must hold:
a restored database without it cannot decrypt its own columns.

**Which protocol per client.** The deciding question is whether the client can show a browser.

| Client | Protocol | Source |
|---|---|---|
| Grafana, OpenWebUI, Paperless-ngx, Audiobookshelf | OIDC | Authelia integration guides exist for all four |
| Jellyfin | LDAP, through the LDAP plugin | TV apps sign in with a username and password and cannot follow an OIDC redirect. Authelia's Jellyfin guide uses the community SSO plugin, which serves a separate login endpoint the TV apps never open |
| Calibre-Web | LDAP | Not among Authelia's OIDC guides; `lldap` ships an example configuration |
| Nextcloud | OIDC through `user_oidc` | Deferred, see the cut below |
| Proxmox VE | OIDC realm | Deferred, see the cut below |

The guides were tested upstream against other versions than those running here - the Paperless
guide against 3.0.5, the Jellyfin guide against 10.10.7. Each client's first step is reading its own
release notes for the pinned version, before any configuration.

**Every application keeps a local administrator.** `root@pam`, Nextcloud's `admin` and each
application's first local account stay enabled and in the password manager. The provider is a
convenience in front of the applications, not the only way into them, which is also the rollback
path for each client: turning its OIDC or LDAP setting off restores the state before.

## Schedule and cut

| Day | Work | Done when |
|---|---|---|
| 2026-09-25 | The rest of the block, without the sshd rollout: apply `apt-metrics`, `auditd` and `journal-central`, decide how the socket-activated nodes are pinned and execute it on one node | A manual drift sweep reports no unexpected change, and `apt_upgrades_pending` comes from every node |
| 2026-09-26 | The node: container, onboarding, roles for `lldap` and Authelia, databases, Tailscale tag and ACL, node and service documents, scrape targets | Authelia's discovery document answers over `tailscale serve`, a test user signs in, both databases appear in the next dump |
| 2026-09-27 | Clients in order: Grafana, OpenWebUI, Paperless-ngx, Jellyfin, then Audiobookshelf and Calibre-Web | Each signs in through the provider and still signs in locally |

**The sshd rollout is not part of the start condition.** Its own decision sets one node per session,
nine nodes do not fit a weekend under that rule, and the rule exists because a failed bind on the
wrong node is a trip to the console. It continues after the weekend at the same pace, and it is
still part of what Terraform waits for.

**The cut.** Grafana, OpenWebUI, Paperless-ngx and Jellyfin are the minimum; the track is closed
when they work. Audiobookshelf and Calibre-Web are done if Sunday allows, otherwise they go to the
small open items and do not hold Terraform. Nextcloud and Proxmox are deferred on purpose rather than
for time: Nextcloud has existing accounts that must be matched to directory users without losing
their files, and Proxmox has one operator whose `root@pam` stays regardless. Both are better
attempted once the provider has run for a while.

## Consequences

- A new node holds credentials for every person on the platform. The argument that retired
  Vaultwarden - an unattended secrets store is worse than none - applies, and is answered by use
  rather than by assertion: every sign-in exercises the provider, so it cannot fall out of use
  unnoticed the way the password manager did.
- A provider outage no longer locks anyone out, because of the local accounts, but it does turn every
  sign-in into a manual step. That is accepted at this scale.
- The node is created by hand, like the off-site VPS. Bringing it under Terraform with
  `terraform import` is the first Proxmox exercise of the next track.
- The Headscale migration, deferred into the Terraform track, needs an OIDC provider for user
  sign-in. This one is that provider.

## Exit

The track closes on 2026-09-27 with the minimum working, or with what is missing written into the
remediation plan and the Terraform start moved to depend on it. It is not left open with no end.
