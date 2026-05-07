# Decision: Migrate Control Plane from Tailscale SaaS to Headscale

## Status

**Deferred** — planned as entry point for Phase 6 (Terraform/IaC).
Not implemented. Decision to migrate is made; timing is not yet.

---

## Context

The current access layer relies on Tailscale, which consists of two distinct components:

| Component | Description | Who operates it |
|---|---|---|
| Tailscale client (`tailscaled`) | WireGuard-based mesh client, open source | Self (on every node) |
| Control plane (`login.tailscale.com`) | Key distribution, node discovery, ACL enforcement, DERP coordination | Tailscale Inc. (SaaS) |

This platform's Zero-Trust model (see [Design Decisions #4](design-decisions.md#4-zero-trust-overlay-tailscale-instead-of-public-reverse-proxy))
was designed around minimizing data exposure and attack surface.
The control plane dependency introduces a structural contradiction with that goal.

### What Tailscale SaaS sees

Tailscale traffic is WireGuard end-to-end encrypted — Tailscale cannot see payload content.
However, the SaaS control plane has persistent visibility into:

- **Full network topology**: every node, its name, OS, Tailscale IP, last-seen timestamp
- **Device names**: node names like `lxc240-vaultwarden`, `lxc220-calibreweb` reveal service inventory
- **ACL policy**: the complete access control ruleset — what is allowed to talk to what
- **Authentication events**: device registration, pre-auth key usage, login events
- **DERP relay traffic**: when P2P connections fail (NAT traversal), encrypted traffic transits Tailscale-operated relay servers
- **Behavioral metadata**: connection timing, duration, frequency — which device connects to which node, and when

The last point is the primary privacy concern for this platform.
Services like Jellyfin (media), Audiobookshelf, and Calibre-Web produce recognizable connection patterns
(e.g. a client connecting to the Jellyfin node for 90 minutes at 22:00).
Combined with device identity, this constitutes a detailed behavioral profile held by a third party.

This directly contradicts the platform's stated goal of maximum data sovereignty and self-hosting.

---

## Decision

Migrate the Tailscale control plane to **Headscale**, a self-hosted open-source
reimplementation of the Tailscale coordination server.

Official documentation: https://headscale.net/

**Timing:** After Phase 5 (Ansible) is complete.
Headscale will serve as the entry point for Phase 6 (Terraform/IaC).

### Why not immediately

- Phase 5 (Ansible) is currently in progress. Completing it first is the higher priority.
- A manual Headscale setup would produce an undocumented snowflake node with no reproducibility.
- The migration affects every node on the platform (~10+ nodes). Without Ansible playbooks for
  the node-migration step, this is significant manual effort with high rollback complexity.
- The operational benefit of implementing this as a full IaC project outweighs the marginal
  privacy benefit of acting immediately. Tailscale's data access is metadata-only; no payload
  content is at risk.

---

## Scope of the Full Solution

Headscale replaces the control plane, but does not eliminate all Tailscale SaaS dependencies.
By default, Tailscale clients fall back to Tailscale-operated DERP relay servers when P2P
connections fail. Full independence requires:

1. **Headscale** — self-hosted control plane (replaces `login.tailscale.com`)
2. **Self-hosted DERP** — relay server for NAT traversal fallback (Tailscale publishes the DERP server code as open source)

Both components are in scope for the Phase 6 implementation.

---

## Infrastructure Requirements

Headscale must be reachable from all nodes, including remote devices outside the home network.
This requires a publicly addressable server — the current platform has no public ingress by design.

**Planned approach:** Hetzner VPS (CX22, ~4 EUR/month) dedicated to the control plane.
This node sits outside the Proxmox infrastructure and is not subject to homelab downtime.

Note: existing WireGuard mesh connections survive a control plane outage temporarily.
New connections and key rotations require Headscale to be reachable.
A dedicated VPS provides availability independent of local infrastructure.

---

## Planned Implementation Approach

### Phase 6 project structure

1. **Exploration run (manual):** Set up Headscale on a temporary VPS manually.
   Understand the configuration model, ACL format differences, node registration flow.
   This run is intentionally discarded — it is a learning exercise, not production.

2. **Terraform:** Provision the Hetzner VPS, DNS record, firewall rules declaratively.

3. **Ansible:** Configure Headscale and DERP on the VPS. Write a playbook for
   re-registering each platform node to the new control server.

4. **Migration:** Execute node migration sequentially per node. Verify connectivity
   before proceeding to the next. Document rollback path.

5. **ACL migration:** Translate the existing Tailscale ACL policy to Headscale's
   policy format. Verify tier segmentation is preserved.

### ACL policy note

The current ACL source of truth is managed in the Tailscale web interface.
Before migration, the policy must be exported and committed to this repository
as a version-controlled file. Headscale uses file-based policy configuration —
this is an improvement over the current model.

---

## Alternatives Considered

### Plain WireGuard (no control plane)

Full control, no SaaS dependency, no Headscale infrastructure to maintain.

Rejected because:
- Manual key management does not scale beyond a small number of nodes
- No ACL enforcement layer
- Loses the mesh topology (point-to-point only)
- Significant regression in operational model

### Stay with Tailscale SaaS indefinitely

Operationally simplest. Privacy concern is metadata-only — no payload exposure.

Rejected because:
- Contradicts the platform's long-term goal of full data sovereignty
- Behavioral metadata is a real privacy concern for personal media and document services
- Vendor dependency acknowledged in [loopback-tailscale-serve.md](loopback-tailscale-serve.md) as a known risk

### Headscale without self-hosted DERP

Partial improvement: control plane self-hosted, DERP still Tailscale-operated.

Acceptable as an intermediate state, but not the target.
Metadata from DERP relay usage (timing, endpoints) remains visible to Tailscale.
Full solution includes self-hosted DERP.

---

## Trade-offs

| Advantage | Cost |
|---|---|
| Control plane data sovereignty | Additional infrastructure to operate and monitor |
| Behavioral metadata no longer visible to third party | Headscale becomes a critical dependency |
| ACL policy becomes a version-controlled file | Tailscale SSH feature not supported by Headscale |
| No vendor lock-in for control plane | iOS requires a modified Tailscale client build (`TS_HEADSCALE`) |
| Free tier limits irrelevant | Full solution requires self-hosted DERP in addition to Headscale |
| Reproducible infrastructure via IaC | One-time migration effort across all nodes |

---

## Related Documents

- [Design Decisions #4: Zero-Trust Overlay (Tailscale)](design-decisions.md#4-zero-trust-overlay-tailscale-instead-of-public-reverse-proxy)
- [Design Decisions #9: Planned Network Hardening](design-decisions.md#9-planned-architectural-evolution-network-hardening--phase-2)
- [Loopback + Tailscale Serve — Vendor Lock-in Awareness](loopback-tailscale-serve.md#vendor-lock-in-awareness)
- [Networking & Zero-Trust Model](../platform/networking.md)
- [Tailscale ACL Model](../platform/tailscale-acl.md)
