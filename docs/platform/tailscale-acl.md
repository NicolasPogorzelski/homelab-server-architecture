# Tailscale ACL & Tagging Model (Policy-as-Code)

## Purpose

This platform uses Tailscale as the only remote-access path and as the identity layer for service-to-service communication.

Principles:

- LAN is not trusted
- No public ingress / no port-forwarding
- Access is identity-based and explicitly allowed
- Policy is managed as code (Tailscale ACL JSON), not ad-hoc per service

Source of truth: The active policy is the Tailscale ACL JSON in the Tailscale admin console.
This document mirrors the intended model. A sanitized version of the active policy is included below.

---

## Tier Model

Nodes are grouped into logical tiers based on trust level and responsibility.

| Tier | Tag | Purpose | Nodes |
|---|---|---|---|
| Admin | `tag:admin` | Human operator devices + management tooling | example-device |
| Tier 0 | `tag:tier0` | Hypervisor / infrastructure control plane | example-device |
| Tier 1 | `tag:tier1` | Security-critical services | example-device |
| Tier 2 | `tag:tier2` | Application services | example-device |
| Storage | `tag:storage` | Persistent data layer | example-device |
| Client | `tag:client` | Trusted end-user devices | example-device |
| Untrusted | `tag:untrusted` | Guest / restricted devices | example-device |

---

## Tag Ownership

All tags are owned by `autogroup:admin` (Tailscale account administrators).

Tags are assigned to nodes via the Tailscale admin console.

```json
"tagOwners": {
    "tag:admin":     ["autogroup:admin"],
    "tag:tier0":     ["autogroup:admin"],
    "tag:tier1":     ["autogroup:admin"],
    "tag:tier2":     ["autogroup:admin"],
    "tag:storage":   ["autogroup:admin"],
    "tag:client":    ["autogroup:admin"],
    "tag:untrusted": ["autogroup:admin"]
}
```

---

## Host Aliases

Named aliases for nodes referenced by IP in ACL rules.

```json
"hosts": {
    "gpu-vm":    "<tailscale-ip-vm100>",
    "nextcloud": "<tailscale-ip-lxc210>"
}
```

---

## ACL Rules (Sanitized)

### Rule 1 — Admin: full infrastructure access

Admin nodes have unrestricted access to all infrastructure and service tiers.
Admin does NOT have implicit access to client or untrusted devices.

```json
{
    "action": "accept",
    "src":    ["tag:admin"],
    "dst": [
        "tag:admin:*",
        "tag:tier0:*",
        "tag:tier1:*",
        "tag:tier2:*",
        "tag:storage:*"
    ]
}
```

Note: `tag:admin:*` was added to allow admin-to-admin communication
(required when multiple admin-tagged nodes exist, e.g. desktop + devops LXC).

### Rule 2 — Tier 0 (Proxmox): workload access only

The hypervisor can reach all workload tiers and storage.
No access to clients or untrusted devices.

```json
{
    "action": "accept",
    "src":    ["tag:tier0"],
    "dst": [
        "tag:tier0:*",
        "tag:tier1:*",
        "tag:tier2:*",
        "tag:storage:*"
    ]
}
```

### Rule 3 — Tier 1 (security-critical): strictly isolated

Tier 1 nodes can communicate with other tier 1 nodes
and access storage via SMB (port 445) only.

No access to tier 0, tier 2, clients, or untrusted.

```json
{
    "action": "accept",
    "src":    ["tag:tier1"],
    "dst": [
        "tag:tier1:*",
        "tag:storage:445"
    ]
}
```

### Rule 4 — Tier 2 (application services): strictly isolated

Same isolation model as tier 1.
Tier 2 nodes can communicate with other tier 2 nodes
and access storage via SMB (port 445) only.

```json
{
    "action": "accept",
    "src":    ["tag:tier2"],
    "dst": [
        "tag:tier2:*",
        "tag:storage:445"
    ]
}
```

### Rule 5 — Clients: explicit service access only

Trusted client devices can access specific service ports only.
No infrastructure access, no storage access.

```json
{
    "action": "accept",
    "src":    ["tag:client"],
    "dst": [
        "gpu-vm:8096",
        "gpu-vm:13378",
        "tag:tier1:443",
        "tag:tier2:443"
    ]
}
```

Allowed services:

- Jellyfin (port 8096 on gpu-vm)
- Audiobookshelf (port 13378 on gpu-vm)
- Tier 1 HTTPS (port 443): Nextcloud, Vaultwarden
- Tier 2 HTTPS (port 443): Calibre-Web

### Rule 6 — Untrusted: minimal access

Guest and restricted devices have access to media services only.

```json
{
    "action": "accept",
    "src":    ["tag:untrusted"],
    "dst": [
        "gpu-vm:8096",
        "gpu-vm:13378",
        "tag:tier2:443"
    ]
}
```

Allowed services:

- Jellyfin (port 8096 on gpu-vm)
- Audiobookshelf (port 13378 on gpu-vm)
- Tier 2 HTTPS (port 443): Calibre-Web

---

## Node Attributes

### Mullvad Exit Nodes

Selected nodes are configured to route internet traffic through Mullvad VPN exit nodes via Tailscale's built-in Mullvad integration.

```json
"nodeAttrs": [
    {"target": ["<tailscale-ip-node-a>"], "attr": ["mullvad"]},
    {"target": ["<tailscale-ip-node-b>"], "attr": ["mullvad"]}
]
```

---

## Access Matrix (Summary)

| Source ↓ / Destination → | admin | tier0 | tier1 | tier2 | storage | client | untrusted |
|---|---|---|---|---|---|---|---|
| **admin** | all | all | all | all | all | — | — |
| **tier0** | — | all | all | all | all | — | — |
| **tier1** | — | — | all | — | 445 | — | — |
| **tier2** | — | — | — | all | 445 | — | — |
| **client** | — | — | 443 | 443 + gpu-vm:8096,13378 | — | — | — |
| **untrusted** | — | — | — | 443 + gpu-vm:8096,13378 | — | — | — |

---

## Administrative Access Model

Administrative access is separated from service-to-service communication.

- Human operators are authenticated via Tailscale identity (user-based auth)
- Service-to-service communication is controlled via tags
- Administrative privileges are not granted implicitly to service tags
- Break-glass access is documented and intentionally minimal

---

## Service Onboarding Checklist (Network)

For every new service that must be reachable remotely or must reach other services:

1. Decide the node tag(s) for this service
2. Update Tailscale ACL JSON (allow rules)
3. Verify connectivity (only the intended ports/targets)
4. Ensure the service itself binds only to Tailscale (or loopback + Tailscale proxy)
5. Document the access model in the service doc

---

## Binding Rules (Zero Trust)

Default rules:

- Services must not bind to LAN interfaces unless explicitly justified
- Prefer:
  - bind to Tailscale IP (service listens directly on tailnet), or
  - bind to loopback and expose via Tailscale Serve (service never listens on LAN)

Both approaches are valid; choose per service based on operational needs.

---

## Documentation Rule

Every `docs/services/*.md` file must include an "Access Model (Zero Trust)" section and reference this document.

---

## Changelog

| Date | Change | Reason |
|---|---|---|
| 2026-03-04 | Added `tag:admin:*` to admin dst | Enable admin-to-admin communication (required after adding LXC250 devops) |
| 2026-03-04 | Changed tier1/tier2 storage port from 2049 (NFS) to 445 (SMB) | NFS was replaced by SMB; port rule was a leftover |
