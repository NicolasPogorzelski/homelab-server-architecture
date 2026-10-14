# The Tailscale Control Plane Moves to Headscale

## Status
Proposed 2026-05-07, deferred. Not started. Runs after the
[identity track](identity-before-terraform.md), whose OIDC provider it needs for user sign-in, as
part of the Terraform track. Supersedes / superseded by: -.

## Context
Tailscale has two parts: the WireGuard client `tailscaled`, open source and run on every node, and
the coordination server (`login.tailscale.com`), operated by Tailscale Inc. Payload is encrypted end
to end, but the coordination server holds:

- the full topology: every node, its name, operating system, Tailscale address and last-seen time;
  node names map the service inventory;
- the complete ACL policy;
- authentication events: registrations, pre-auth keys, logins;
- connection metadata: which device connects to which node, when and for how long. Media and
  document services produce recognisable patterns (a client on the Jellyfin node for 90 minutes in
  the evening);
- relayed traffic, encrypted, whenever two peers fall back to a Tailscale-operated DERP server.

Every service on the platform is reached through the tailnet
([loopback + Tailscale Serve](loopback-tailscale-serve.md),
[media over the tailnet](media-over-the-tailnet.md)), so this metadata covers all use of it. The
platform's goal of self-hosting its data does not hold for the metadata as long as a third party
runs the control plane.

## Options
- **Stay on Tailscale SaaS.** Lost: simplest, and payload stays private, but the usage metadata
  above stays with a vendor and the ACL lives in its console.
- **Plain WireGuard without a control plane.** Lost: manual key distribution, no ACL layer, no mesh;
  a regression in operation for every node.
- **Headscale with Tailscale's DERP servers.** Acceptable as an intermediate state, not as the
  target: relay metadata stays visible to Tailscale.
- **Headscale plus a self-hosted DERP relay.** Chosen.

## Decision
The coordination server is replaced by Headscale, the open-source reimplementation
(https://headscale.net/), with a self-hosted DERP relay beside it. Both run on a small public VPS
outside the Proxmox host, because every client, including mobile ones outside the home, must reach
the control plane, and the platform has no public ingress by design.

Order of work:

1. A throwaway Headscale on a temporary VPS, to learn its configuration, policy format and
   registration flow. Discarded afterwards.
2. Terraform provisions the VPS, its DNS record and firewall.
3. Ansible configures Headscale and DERP and re-registers each node, one node at a time with
   connectivity checked before the next.
4. The ACL in [tailscale-acl.md](../platform/tailscale-acl.md) is translated to Headscale's policy
   file; every accept and deny the policy tests there assert must still hold.

The start waits for two reasons. A hand-built control plane would be an unreproducible node that
every other node depends on. And re-registering all ten nodes plus the client devices without
playbooks is high effort with a hard rollback, against a risk that is metadata only.

## Consequences
- The ACL becomes a file in the repository. Today the Tailscale admin console is its source of
  truth and `tailscale-acl.md` is a hand-applied mirror.
- Headscale becomes a dependency of every connection. Established tunnels survive its outage for a
  while; new connections, registrations and key rotations do not. It needs monitoring and backup of
  its own.
- One more public machine to patch, on a monthly cost.
- Client features that depend on Tailscale's server have to be checked against the Headscale
  version deployed before the migration.

## Related Documents
- [DD-4: Zero-trust overlay](design-decisions.md#dd-4)
- [Identity before Terraform](identity-before-terraform.md)
- [Tailscale ACL model](../platform/tailscale-acl.md)
- [Networking](../platform/networking.md)
