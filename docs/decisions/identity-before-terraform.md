# An Identity Track Between the Exercise Block and Terraform

## Status
Proposed 2026-09-24. Not started. Amends the start condition in
[the exercise-scope decision](exercise-scope-before-terraform.md): Terraform begins when the
exercise block is done and this track is closed. Supersedes / superseded by: -.

## Context
Network access is identity-based (the Tailscale ACL decides which device reaches which node), but
each application keeps its own user table. Measured 2026-09-24:

| Where | What holds identities |
|---|---|
| Nextcloud | Local accounts plus `admin`; `user_ldap` installed and disabled |
| Proxmox VE | Realms `pam` and `pve`, one user, `root@pam` |
| Paperless-ngx, OpenWebUI, Grafana | Local accounts each |
| Jellyfin, Audiobookshelf, Calibre-Web | Local accounts each |

There is no directory and no identity provider: adding a person means eight account creations,
removing one means remembering all eight. An LDAP directory (`lldap`) with three LDAP clients was
built in a separate project; OIDC was not. Adding the missing half is the learning goal. One place
to add and remove a person is a real but small operational gain at this user count.

Two constraints bound the design:

- **No reverse proxy.** Every service is published by `tailscale serve` on its own node. OIDC still
  works, since it is a redirect between browser, application and provider; a proxy that checks a
  session before each request is out of scope.
- **`ts.net` is on the Public Suffix List** as a single entry. Authelia refuses a cookie domain equal
  to a public suffix and requires it to contain its portal's host name
  ([session configuration](https://www.authelia.com/configuration/session/introduction/)). The
  widest possible cookie, `<tailnet-id>.ts.net`, would reach every node, so the cookie is scoped to
  the provider's own `<node>.<tailnet-id>.ts.net`.

## Options
- **Keycloak or Authentik as provider.** Lost on footprint: about 7 GB of host memory and 13 GB of
  thin pool free, on a host that powers down nightly.
- **LDAP only.** Lost: repeats what was already built and cannot serve browser sign-in flows.
- **`lldap` as directory and Authelia as OIDC provider on one new node.** Chosen; `lldap`'s
  upstream README names Authelia for OAuth and OpenID.

## Decision
- **Storage.** Both databases on lxc260 through `postgresql_provisioning`, so the nightly dump and
  the monthly restore test cover them from the first night. Authelia's `encryption_key` goes into
  the vault and the escrow: a restored database cannot decrypt its columns without it.
- **Protocol per client**, decided by whether the client can show a browser:

| Client | Protocol | Reason |
|---|---|---|
| Grafana, OpenWebUI, Paperless-ngx, Audiobookshelf | OIDC | Authelia integration guides exist for all four |
| Jellyfin | LDAP plugin | TV apps sign in with username and password and cannot follow an OIDC redirect |
| Calibre-Web | LDAP | No Authelia OIDC guide; `lldap` ships an example configuration |
| Nextcloud | OIDC through `user_oidc` | Deferred: existing accounts must be matched to directory users without losing files |
| Proxmox VE | OIDC realm | Deferred: one administrator, whose `root@pam` stays regardless |

- **Local administrators stay.** `root@pam`, Nextcloud's `admin` and each application's first local
  account stay enabled. Turning a client's OIDC or LDAP setting off is its rollback.
- **Scope.** The track is closed when Grafana, OpenWebUI, Paperless-ngx and Jellyfin sign in
  through the provider and still sign in locally. Audiobookshelf and Calibre-Web follow if time
  allows, otherwise they become remediation items and do not hold Terraform.
- **Version check first.** Upstream guides were tested against other versions than those deployed;
  each client starts by reading the release notes of its pinned version.

## Consequences
- A new node holds credentials for every person on the platform. Every sign-in exercises it, so it
  cannot fall out of use unnoticed the way Vaultwarden did
  ([decommission](vaultwarden-decommission.md)).
- A provider outage turns sign-ins into a manual step through the local accounts; accepted.
- The node is created by hand; adopting it with `terraform import` is the first Proxmox exercise of
  the Terraform track.
- The [Headscale migration](headscale-migration.md) needs an OIDC provider for user sign-in; this
  is that provider.
- The [sshd rollout](sshd-listen-address.md) is not part of this track's start condition.
