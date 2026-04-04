# Decision: Central DevOps LXC (LXC250)

## Context

Code and infrastructure changes were previously made from multiple machines (desktop, notebook).
This created synchronization overhead and inconsistent Git state across devices.

A centralized management node eliminates this problem:
all changes are made in one place, all other nodes only pull.

---

## Decision

Create a dedicated unprivileged Debian LXC (CTID 250) as the central DevOps workstation.

All Git operations, code editing, Ansible execution, and IaC work happen exclusively on this node.

---

## Alternatives Considered

### VM instead of LXC

A full VM was considered but rejected:

- No hardware passthrough required (no GPU, no special kernel)
- No Docker needed on this node (build/test VMs can be added later if needed)
- LXC provides the same user experience with less overhead
- All existing service LXCs already use the same toolchain (Tailscale, pct exec, Debian)
- 2 GB RAM in an LXC has almost no overhead; in a VM, QEMU and a separate kernel consume part of that budget

### Ubuntu Server instead of Debian

Considered but not chosen:

- Slightly larger footprint than Debian
- Would maintain the OS split (VM100 = Ubuntu, rest = Debian)
- No meaningful advantage for this workload

---

## Specification

| Property | Value |
|---|---|
| CTID | 250 |
| Hostname | devops |
| OS | Debian 12 (bookworm) |
| Cores | 2 |
| RAM | 2048 MB |
| Swap | 512 MB |
| Disk | 8 GB (local-lvm) |
| Unprivileged | Yes |
| Nesting | Enabled (required for Tailscale) |
| Tailscale Tag | `tag:admin` |
| Onboot | Yes |

---

## CTID Schema Rationale

The CTID 250 follows the established numbering model:

- 100–109: Hardware-proximate VMs (GPU, Storage)
- 200–209: Monitoring
- 210–219: Cloud (Nextcloud)
- 220–229: Media (Calibre-Web)
- 230–239: AI Stack (OpenWebUI)
- 240–249: Secrets (Vaultwarden)
- 250–259: DevOps / Management Tooling
- 260–269: Database / Platform Services
---

## Tailscale Tag Rationale

`tag:admin` was chosen because:

- The DevOps node requires broad access to all tiers (tier0, tier1, tier2, storage) for management and Ansible
- This matches the access profile of existing admin devices (desktop, notebook)
- A dedicated `tag:devops` was considered but deferred to avoid premature ACL complexity
- Can be revisited when automated (non-human) access patterns emerge (e.g., CI runners, scheduled Ansible)

### ACL Impact

Adding a second `tag:admin` node revealed a gap in the existing ACL policy:
admin-to-admin communication was not explicitly allowed.

Fix applied:
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

---

## Access Model

- SSH key-based authentication (ED25519) from admin devices
- Password authentication available as fallback
- VS Code Remote SSH for graphical editing (optional)
- Direct terminal SSH + tmux/neovim for lightweight work

---

## Trade-offs

- Single point of failure for all Git/IaC operations (acceptable for a single-operator homelab)
- Requires discipline: no ad-hoc changes from other machines
- 2 GB RAM limits concurrent heavy workloads (sufficient for Git + Ansible + editing)

---

## Related Documents

- [Architecture Overview](../architecture/overview.md)
- [Tailscale ACL Model](../platform/tailscale-acl.md)
- [Node Documentation: LXC250](../nodes/lxc250.md)
