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

ACL enforcement uses a Tailscale policy (JSON) built from node tags and identity-based grants.
The Tailscale admin console is the source of truth; the repository mirrors the policy and changes
are applied to the console by hand, not synced by CI.

See: [docs/platform/tailscale-acl.md](./tailscale-acl.md)

## Node Segmentation

Nodes are grouped into logical tiers to reduce lateral movement:

- Infrastructure nodes (hypervisor, storage)
- Service nodes (VMs, LXCs)
- Client devices
- Restricted / untrusted clients

Access between tiers is explicitly controlled via ACL policies.

## LAN Access

No service is reachable from the LAN. Media streaming was the last exception, and
it ended when Jellyfin and Audiobookshelf moved to the tailnet
([decision](../decisions/media-over-the-tailnet.md), [vm100](../nodes/vm100.md#no-media-ports-on-the-lan)). The `lan_guard` nftables table on every
node's LAN interface drops new inbound connections; the named exceptions are SMB to vm102 from
vm100 and the hypervisor, and break-glass SSH and netconsole to the hypervisor. The tailnet is never
filtered by it. See the `lan_guard` role in [ansible.md](ansible.md#roles).

## Design Goal

Minimize attack surface while preserving operational usability.
