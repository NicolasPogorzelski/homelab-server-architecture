# Networking & Zero-Trust Model

The infrastructure follows a zero-trust inspired network design using an identity-based overlay network.

## External Exposure

- No router port forwarding
- No publicly exposed reverse proxy
- No publicly reachable HTTP endpoints

## Remote Access

Remote access is exclusively provided through an identity-based overlay network (Tailscale).

- Peer-to-peer encrypted connections
- Device-based authentication
- Explicit ACL rules between nodes
- Tiered segmentation model

ACL enforcement is implemented via **Tailscale ACL policy (JSON)** using
node tags and identity-based allow rules (policy-as-code).

See: [docs/platform/tailscale-acl.md](./tailscale-acl.md)

## Node Segmentation

Nodes are grouped into logical tiers to reduce lateral movement:

- Infrastructure nodes (hypervisor, storage)
- Service nodes (VMs, LXCs)
- Client devices
- Restricted / untrusted clients

Access between tiers is explicitly controlled via ACL policies.

## LAN Access

Certain performance-sensitive services (e.g., media streaming) are additionally reachable in the local network. This is a deliberate trade-off between security and performance under a defined threat model.

## Design Goal

Minimize attack surface while preserving operational usability.
