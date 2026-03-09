# Architecture Design Decisions

# Design Philosophy

The system prioritizes:

- Deterministic recovery
- Explicit dependency modeling
- Operational transparency
- Security by segmentation
- Minimal coupling between layers
- Operational predictability over theoretical elegance


---

This document outlines key architectural decisions, alternatives considered, and trade-offs.

---

## 1. SnapRAID + MergerFS instead of ZFS

### Decision
Use SnapRAID for parity and MergerFS for namespace abstraction.

### Rationale
- Lower RAM requirements compared to ZFS
- Heterogeneous disk sizes supported
- Optimized for mostly-static media workloads
- Easier incremental expansion
- Clear separation between redundancy (SnapRAID) and namespace abstraction (MergerFS)

### Trade-offs
- No real-time redundancy
- Sync window vulnerability
- Operational discipline required (sync + scrub cadence)

---

## 2. Dedicated Storage VM instead of Direct Host Mounting

### Decision
Isolate storage services in VM102.

### Rationale
- Clear separation of responsibilities
- Reduced blast radius
- Easier rebuild and migration
- Clean abstraction boundary between storage and compute layers
- Simplifies backup/export logic

### Trade-offs
- Slight virtualization overhead
- Additional internal network hop

---

## 3. SMB instead of NFS (after evaluation)

### Initial Evaluation
NFS was initially tested as the primary storage export protocol.

### Observed Challenges
When combined with:
- Unprivileged LXC containers
- UID/GID shifting (100000+ namespace mapping)
- Root-squash behavior
- Consistent identity mapping across host, VM and LXC boundaries

NFS introduced increased complexity and instability in permission handling.

### Decision
Switch to SMB with explicit per-service authentication and ownership enforcement.

### Rationale
- Explicit per-service identities (`valid users`)
- Deterministic ownership control via:
  - `force user`
  - `force group`
  - `create mask`
  - `directory mask`
- Easier reasoning about permission boundaries
- Reduced ambiguity in UID mapping across isolation layers

### Trade-offs
- Slight protocol overhead
- More configuration surface compared to basic NFS
- Requires credential management per service

The decision prioritizes operational predictability over theoretical performance gains.

---

## 4. Zero-Trust Overlay (Tailscale) instead of Public Reverse Proxy

### Decision
No public ingress. Remote access via identity-based overlay network.

### Rationale
- Significantly reduced attack surface
- No router port-forwarding
- Access tied to device identity
- Clear separation between LAN exposure and remote access

### Trade-offs
- Requires client installation
- Not suitable for public-facing multi-user services
- Overlay dependency

---

## 5. Unprivileged LXC Containers

### Decision
All service LXCs run unprivileged.

### Rationale
- Prevent root-equivalence between container and host
- Stronger isolation guarantees
- Aligns with least-privilege philosophy
- Minimizes blast radius of container compromise

### Trade-offs
- Increased complexity in UID/GID mapping
- Mount permissions require deliberate configuration
- Some kernel features unavailable

---

## 6. Read-Only Media Consumers

### Decision
Media services receive read-only access to storage.

### Rationale
- Minimize blast radius
- Prevent accidental modification/deletion
- Strict separation between producers (Nextcloud, Vaultwarden) and consumers (Jellyfin, Audiobookshelf, Calibre-Web)

### Trade-offs
- Write operations require controlled ingest paths
- Additional planning for content workflows

---

## 7. Monitoring via Dedicated LXC

### Decision
Monitoring stack isolated in LXC200.

### Rationale
- Observability independent from application failures
- Easier troubleshooting
- Clear layering (monitoring does not depend on service containers)

### Trade-offs
- Slight resource overhead
- Additional configuration and maintenance surface

---

## 8. LAN Exposure for Performance-Critical Workloads

### Decision

Performance-critical services remain reachable from the local network:

- Media services (Jellyfin, Audiobookshelf on VM100) — for high-bitrate LAN streaming
- Nextcloud (LXC210) — for high-volume LAN uploads (e.g. multi-GB file imports)

### Rationale

Remote access is secured via Tailscale (identity-based Zero-Trust overlay).

However, local media streaming is intentionally allowed over LAN to avoid unnecessary bandwidth constraints.

The current upstream bandwidth (~50 Mbit/s) would significantly limit high-bitrate media streaming if all traffic were forced through the overlay network.

LAN access is therefore maintained as a performance-oriented exception.

### Security Consideration

- No public exposure
- Identity-based remote access enforced via Tailscale
- LAN exposure restricted to performance-critical workloads only
- Vaultwarden is not LAN-exposed (loopback-only + Tailscale Serve)
- Nextcloud is LAN-exposed but protected by Apache TLS and application-level authentication
- All LAN-exposed services still require authentication — no anonymous access

This represents a deliberate trade-off between strict network isolation and practical throughput requirements.


---

## 9. Planned Architectural Evolution (Network Hardening – Phase 2)

The current hybrid LAN + Tailscale access model is a documented performance trade-off influenced by upstream bandwidth limitations (~50 Mbit upload).

Media workloads (e.g., Jellyfin, Audiobookshelf) are intentionally reachable via LAN to avoid performance bottlenecks and unnecessary overlay overhead.

With increased upstream capacity (~500 Mbit planned), the architecture is designed to evolve toward a stricter identity-bound model:

### Planned Changes

- Restrict SMB exposure to the Tailscale interface only
- Remove implicit LAN trust for storage services
- Enforce identity-bound access for all service mounts
- Eliminate direct LAN service exposure (media included)
- Introduce optional VLAN-based segmentation for internal traffic separation

### Rationale

This evolution reflects a shift from a pragmatic hybrid networking model toward full zero-trust enforcement once bandwidth constraints no longer justify LAN-level exposure.

The design prioritizes:

- Explicit trust boundaries
- Reduced lateral movement potential
- Consistent access control semantics
- Security model clarity over convenience

The current implementation is therefore intentionally transitional and documented as such.


See: [docs/platform/tailscale-acl.md](../platform/tailscale-acl.md)

---

## 10. Docker Host Networking Eliminates Container DNS

### Context

All Docker services in the monitoring stack (Prometheus, Grafana, Node Exporter) use `network_mode: host` to bind directly to loopback (`127.0.0.1`). This enables the Tailscale Serve reverse proxy pattern without exposing services on `0.0.0.0`.

### Decision

All inter-service communication in host-networked Docker stacks must use `127.0.0.1` (or explicit host IPs) instead of container names.

### Rationale

In Docker's default bridge mode, an internal DNS resolver allows containers to reach each other by name (e.g., `http://prometheus:9090`). When `network_mode: host` is enabled, containers share the host's network stack directly — Docker does not create a virtual network and therefore provides no DNS resolution between containers.

This caused a concrete failure: Grafana's provisioned datasource referenced `http://prometheus:9090`, which became unresolvable after the switch to host networking. Dashboards failed silently until the URL was corrected to `http://127.0.0.1:9090`.

### Implications

- Any service-to-service reference in configuration files, environment variables, or provisioning templates must use `127.0.0.1` (or the host's Tailscale IP) — never container names
- This applies to all current and future Docker stacks using `network_mode: host`
- Provisioning files (e.g., Grafana datasources) are managed as IaC templates (`.example` with placeholders) to make this explicit

### Considered Alternative

Bridge mode with loopback port mapping was evaluated as an alternative:
```yaml
ports:
  - "127.0.0.1:3000:3000"
```

This would preserve Docker's internal DNS (containers reachable by name) and maintain Docker-level network isolation between containers. Each port would be bound to `127.0.0.1` on the host side, remaining compatible with Tailscale Serve.

This approach was not chosen because the monitoring stack runs in a dedicated unprivileged LXC (DD#7, DD#5) where all containers are expected to communicate freely. Docker-internal isolation provides no meaningful security benefit in this context. Host networking reduces configuration complexity by eliminating custom networks, port mappings, and NAT overhead.

### Trade-offs

- Loss of Docker's built-in service discovery and inter-container isolation
- Configuration requires explicit address management
- Accepted trade-off for reduced complexity, loopback-only binding, and Tailscale Serve compatibility
- Isolation is enforced at deeper layers: unprivileged LXC (DD#5), loopback binding, and Tailscale ACL (DD#4)

---

## 11. Monitoring Requires Explicit Outbound ACLs for Scrape Targets

### Context

Prometheus (LXC200, `tag:monitoring`) scrapes Node Exporter on the Proxmox host (`tag:tier0`, port 9100) via Tailscale. The initial ACL policy defined inbound access to `tag:monitoring` (from `tag:admin`) but no outbound rules for `tag:monitoring` itself.

### Incident

After a container restart (RAM reallocation), Prometheus lost connectivity to the host Node Exporter. Disk temperature metrics (`smart_temperature_celsius`) stopped appearing in Grafana.

Root cause: Tailscale evaluates ACLs when establishing new peer connections. The previous connection had survived as a pre-existing WireGuard tunnel despite the missing rule. The container restart forced a fresh connection attempt, which was correctly denied by the ACL policy.

### Decision

`tag:monitoring` requires explicit outbound ACL rules to all scrape targets. Access is restricted to the Node Exporter port only.
```jsonc
{
    "action": "accept",
    "src":    ["tag:monitoring"],
    "dst": [
        "tag:tier0:9100",
        "tag:tier1:9100",
        "tag:tier2:9100",
        "tag:storage:9100",
    ],
}
```

### Rationale

- Tailscale ACLs are deny-by-default — every direction of traffic requires an explicit rule
- Inbound access (admin → monitoring) does not imply outbound access (monitoring → targets)
- Pre-existing tunnels can mask missing rules until the next connection reset
- Port restriction (9100 only) enforces least-privilege: Prometheus can scrape metrics but cannot SSH or access other services

### Implications

- Every new scrape target tag must be added to this rule
- ACL changes should be validated after any container or Tailscale restart, not only after policy edits
- Pre-existing connections are not proof that ACLs are correct

### Trade-offs

- Additional ACL maintenance when adding new monitoring targets
- Accepted for explicit, auditable access control over implicit tunnel persistence
