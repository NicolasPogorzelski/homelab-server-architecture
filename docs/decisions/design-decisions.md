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

## 8. LAN Exposure for Media Workloads (Performance Trade-off)

### Decision

Media services (Jellyfin, Audiobookshelf) remain reachable from the local network.

### Rationale

Remote access is secured via Tailscale (identity-based Zero-Trust overlay).

However, local media streaming is intentionally allowed over LAN to avoid unnecessary bandwidth constraints.

The current upstream bandwidth (~50 Mbit/s) would significantly limit high-bitrate media streaming if all traffic were forced through the overlay network.

LAN access is therefore maintained as a performance-oriented exception.

### Security Consideration

- No public exposure
- Identity-based remote access enforced via Tailscale
- LAN exposure restricted to media workloads only
- Sensitive services (Nextcloud, Vaultwarden) are not exposed on LAN without authentication

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


See: [docs/platform/tailscale-acl.md](docs/platform/tailscale-acl.md)
