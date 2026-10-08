# Networking & Zero-Trust Model

The infrastructure follows a Zero-Trust access model using an identity-based overlay network (Tailscale).

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

ACL enforcement is implemented via Tailscale ACL policy (JSON) using
node tags and identity-based allow rules (policy-as-code).

The active ACL policy is managed in Tailscale as JSON (source of truth).
This repository documents the intended model and tagging structure.

See: [docs/platform/tailscale-acl.md](./tailscale-acl.md)

## Node Segmentation

Nodes are grouped into logical tiers to reduce lateral movement:

- Infrastructure nodes (hypervisor, storage)
- Service nodes (VMs, LXCs)
- Client devices
- Restricted / untrusted clients

Access between tiers is explicitly controlled via ACL policies.

## LAN Access

No service is reachable from the LAN since 2026-10-01. Media streaming was the last exception, and
it ended when Jellyfin and Audiobookshelf moved off the LAN
([vm100](../nodes/vm100.md#no-media-ports-on-the-lan)). The `lan_guard` nftables table on every
node's LAN interface drops new inbound connections; the named exceptions are SMB to vm102 from
vm100 and the hypervisor, and break-glass SSH and netconsole to the hypervisor. The tailnet is never
filtered by it. See [ansible.md](ansible.md) for the role.

## Design Goal

Minimize attack surface while preserving operational usability.
