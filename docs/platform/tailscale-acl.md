# Tailscale ACL & Tagging Model (Policy-as-Code)

## Purpose
This platform uses Tailscale as the only remote-access path and as the identity layer for service-to-service communication.

Principles:
- LAN is not trusted
- no public ingress / no port-forwarding
- access is identity-based and explicitly allowed
- policy is managed as code (Tailscale ACL JSON), not ad-hoc per service

---

## Core Concepts

### Tags
Tags represent service roles (providers) and consumer groups.

Example categories (conceptual):
- `tag:ai-stack` (AI services / consumers like OpenWebUI)
- `tag:postgres` (database provider)
- `tag:cloud` (cloud services)
- `tag:secrets` (Vault/secret-related)
- `tag:monitoring` (observability tooling)

Tags are assigned to nodes and then referenced in ACL rules.

### ACL Rules
ACL rules define which tagged identities may connect to which destinations.

Pattern:

    tag:<consumer>  →  tag:<provider>

Example:

    tag:ai-stack  →  tag:postgres

Meaning:
- AI services may open TCP connections to the PostgreSQL service node(s)
- other nodes are blocked at the network layer

---

## Service Onboarding Checklist (Network)
For every new service that must be reachable remotely or must reach other services:

1. decide the node tag(s) for this service
2. update Tailscale ACL JSON (allow rules)
3. verify connectivity (only the intended ports/targets)
4. ensure the service itself binds only to Tailscale (or loopback + Tailscale proxy)
5. document the access model in the service doc

---

## Binding Rules (Zero Trust)
Default rules:
- Services must not bind to LAN interfaces unless explicitly justified.
- Prefer:
  - bind to Tailscale IP (service listens directly on tailnet), or
  - bind to loopback and expose via Tailscale Serve (service never listens on LAN)

Both approaches are valid; choose per service based on operational needs.

---

## Documentation Rule
Every `docs/services/*.md` file must include an "Access Model (Zero Trust)" section and reference this document.

