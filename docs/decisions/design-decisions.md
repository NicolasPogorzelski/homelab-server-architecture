# Architecture Design Decisions

The platform's foundational decisions, each with its rationale and trade-offs. Later decisions have
records of their own in this directory.

## Design Principles

- Deterministic recovery
- Explicit dependency modeling
- Operational transparency
- Security by segmentation
- Minimal coupling between layers
- Operational predictability over theoretical elegance

## Decisions

| # | Decision | Status | Why |
|---|---|---|---|
| [1](#dd-1) | SnapRAID + MergerFS instead of ZFS | Implemented | Lower RAM than ZFS, heterogeneous disk sizes, incremental expansion; parity and namespace stay separable |
| [2](#dd-2) | Dedicated Storage VM instead of Direct Host Mounting | Implemented | Separates storage from compute, so a rebuild or migration touches one guest |
| [3](#dd-3) | SMB instead of NFS (after evaluation) | Implemented | Per-service identities and deterministic ownership through `force user` and the masks |
| [4](#dd-4) | Zero-Trust Overlay (Tailscale) instead of Public Reverse Proxy | Implemented | No port-forwarding at all; access is tied to device identity; network position grants nothing |
| [5](#dd-5) | Unprivileged LXC Containers | Implemented | No root-equivalence between container and host, at the cost of UID mapping work |
| [6](#dd-6) | Read-Only Media Consumers | Implemented | Producers and consumers of the archive are separated, so a consumer cannot delete |
| [7](#dd-7) | Monitoring via Dedicated LXC | Implemented | Observability that does not depend on the services it watches |
| [8](#dd-8) | LAN Exposure for Performance-Critical Workloads | Superseded 2026-10-01 by [Media Over the Tailnet](media-over-the-tailnet.md) | Same-LAN peers connect directly, so the uplink was never the limit |
| [9](#dd-9) | Planned Architectural Evolution (Network Hardening - Phase 2) | Superseded in part 2026-10-01 by [Media Over the Tailnet](media-over-the-tailnet.md) | The LAN service exposure is gone; the SMB storage path and VLANs remain open |
| [10](#dd-10) | Docker Host Networking Eliminates Container DNS | Implemented | `network_mode: host` removes Docker's DNS resolver, so container names stop resolving |
| [11](#dd-11) | Monitoring Requires Explicit Outbound ACLs for Scrape Targets | Implemented | Tailscale ACLs are deny-by-default in both directions; inbound access implies no outbound |
| [12](#dd-12) | PostgreSQL Uses a Dedicated Platform Tag Instead of a Tier Tag | Implemented | A tier tag would grant every service in that tier access to the database on all ports |
| [13](#dd-13) | Standardized TUN Configuration for Tailscale-Capable LXCs | Implemented | Both the cgroup rule and the mount entry are required; either alone leaves TUN unusable |

Anchors are explicit `dd-<n>` ids, so rewording a heading does not break links to it.

---

<a id="dd-1"></a>

## 1. SnapRAID + MergerFS instead of ZFS

**Decision.** SnapRAID provides parity, MergerFS the pooled namespace.

**Rationale.** Lower RAM requirements than ZFS; heterogeneous disk sizes; suited to mostly static
media; incremental expansion one disk at a time; redundancy (SnapRAID) and namespace (MergerFS)
stay separate.

**Trade-offs.** No real-time redundancy: data written since the last sync is unprotected. Sync and
scrub run on a schedule (`snapraid_maintenance` defaults), and the alerts watch that they do.

---

<a id="dd-2"></a>

## 2. Dedicated Storage VM instead of Direct Host Mounting

**Decision.** Storage services run in vm102.

**Rationale.** Clear separation of responsibilities and a smaller blast radius; a clean boundary
between storage and compute; rebuild, migration and export logic touch one guest.

**Trade-offs.** Slight virtualization overhead and one more network hop.

---

<a id="dd-3"></a>

## 3. SMB instead of NFS (after evaluation)

**Evaluation.** NFS was tested first as the export protocol. Combined with unprivileged LXCs, UID/GID
shifting (the 100000+ namespace mapping), root squash and identity mapping across host, VM and LXC
boundaries, it made permission handling complex and unstable.

**Decision.** SMB with per-service authentication and enforced ownership.

**Rationale.** Explicit per-service identities (`valid users`); deterministic ownership through
`force user`, `force group`, `create mask` and `directory mask`; permission boundaries that are
easier to reason about across isolation layers.

**Trade-offs.** Some protocol overhead, more configuration than basic NFS, and credentials to manage
per service.

---

<a id="dd-4"></a>

## 4. Zero-Trust Overlay (Tailscale) instead of Public Reverse Proxy

**Decision.** No public ingress. Remote access through an identity-based overlay network.

**Rationale.** A much smaller attack surface; no router port forwarding; access tied to device
identity. How services bind inside the overlay is decided in
[Loopback + Tailscale Serve](loopback-tailscale-serve.md).

**Trade-offs.** Every client needs Tailscale; unsuitable for public multi-user services; the platform
depends on the overlay and on its control plane ([Headscale migration](headscale-migration.md)).

---

<a id="dd-5"></a>

## 5. Unprivileged LXC Containers

**Decision.** All service LXCs run unprivileged.

**Rationale.** No root-equivalence between container and host; stronger isolation; least privilege;
a smaller blast radius when a container is compromised.

**Trade-offs.** UID/GID mapping work, deliberate mount permissions, and some kernel features
unavailable.

---

<a id="dd-6"></a>

## 6. Read-Only Media Consumers

**Decision.** Media services get read-only access to storage.

**Rationale.** Producers and consumers are separated: Nextcloud and the admin workstation's media
shares write; Jellyfin, Audiobookshelf and Calibre-Web read. A compromised or misbehaving consumer
cannot modify or delete the archive.

**Trade-offs.** Writes need controlled ingest paths, such as the Calibre import job
([Calibre auto-import](calibre-cifs-sqlite-import.md)).

---

<a id="dd-7"></a>

## 7. Monitoring via Dedicated LXC

**Decision.** The monitoring stack runs in lxc200.

**Rationale.** Observability independent of application failures; monitoring does not depend on the
service containers it watches.

**Trade-offs.** Some resource overhead and one more node to maintain.

---

<a id="dd-8"></a>

## 8. LAN Exposure for Performance-Critical Workloads

**Status.** Superseded 2026-10-01 by [Media Over the Tailnet](media-over-the-tailnet.md). No service
is reachable on the LAN; `lan_guard` drops new inbound LAN connections on every node.

**Decision (superseded).** Jellyfin and Audiobookshelf on vm100 and Nextcloud on lxc210 stayed
reachable on the LAN, for high-bitrate streaming and large uploads at home.

**Rationale (superseded).** The uplink (about 50 Mbit/s) was assumed to cap all overlay traffic.
Measured 2026-10-01, peers on the same LAN connect directly at close to link speed, so the
assumption did not hold.

---

<a id="dd-9"></a>

## 9. Planned Architectural Evolution (Network Hardening - Phase 2)

**Status.** Superseded in part 2026-10-01. The LAN-exposure items were carried out by
[Media Over the Tailnet](media-over-the-tailnet.md) and `lan_guard`, without waiting for a faster
uplink.

**Plan and state.**

| Planned change | State |
|---|---|
| Eliminate direct LAN service exposure, media included | Done 2026-10-01 ([Media Over the Tailnet](media-over-the-tailnet.md)) |
| Remove implicit LAN trust | Done 2026-10-01: `lan_guard` drops new inbound LAN connections on every node |
| Restrict SMB to identity-bound paths | Open: vm100 and the hypervisor still mount over the LAN ([SMB bind](smb-bind-and-lan-access.md), storage network item in the [remediation plan](../platform/remediation-plan.md)) |
| Optional VLAN segmentation for internal traffic | Not started |

**Rationale.** Explicit trust boundaries, less room for lateral movement, and one access-control
model for every path. Access rules: [tailscale-acl.md](../platform/tailscale-acl.md).

---

<a id="dd-10"></a>

## 10. Docker Host Networking Eliminates Container DNS

**Context.** The monitoring stack (`docker/monitoring/docker-compose.yml`) runs every service with
`network_mode: host`, so each binds loopback directly and `tailscale serve` publishes it without a
listener on `0.0.0.0`.

**Decision.** Services in host-networked stacks reach each other at `127.0.0.1` (or an explicit
host address), never by container name.

**Rationale.** With host networking Docker creates no virtual network and so no DNS between
containers. Grafana's provisioned datasource pointed at `http://prometheus:9090`, which stopped
resolving after the switch; dashboards failed silently until it read `http://127.0.0.1:9090`.

**Implications.** Every service reference in configuration, environment or provisioning uses an
address. The Grafana datasource is a template with placeholders
(`docker/monitoring/grafana/provisioning/datasources/prometheus.yml.example`).

**Alternative.** Bridge mode with loopback port mappings (`127.0.0.1:3000:3000`) keeps container DNS
and Docker's isolation between containers. Not chosen: the stack runs in a dedicated unprivileged
LXC (DD-7, DD-5) whose containers are meant to talk freely, so that isolation buys little, and host
networking removes custom networks, port mappings and NAT.

**Trade-offs.** No built-in service discovery or inter-container isolation; addresses are managed
explicitly. Isolation sits in the unprivileged LXC, the loopback bind and the Tailscale ACL.

---

<a id="dd-11"></a>

## 11. Monitoring Requires Explicit Outbound ACLs for Scrape Targets

**Context.** Prometheus on lxc200 (`tag:monitoring`) scrapes exporters across the tailnet. The first
policy granted access to `tag:monitoring` but nothing from it. After a container restart, Prometheus
lost the host's node_exporter: the previous WireGuard connection had outlived the missing rule, and
the fresh connection was denied.

**Decision.** `tag:monitoring` is granted each scrape and probe target explicitly, port by port, and
nothing else. The current grant is
[Rule 1 in tailscale-acl.md](../platform/tailscale-acl.md#rule-1---monitoring-scrapes-and-service-probes).

**Rationale.** Tailscale ACLs are deny-by-default in every direction; access to a node implies no
access from it. A pre-existing tunnel can hide a missing rule until the next reconnect. Port-level
grants let Prometheus read metrics without reaching SSH or the services.

**Implications.** A new scrape target or tag needs a rule change. After a container or Tailscale
restart, check the targets, not only after policy edits: a working existing connection does not
prove the policy.

---

<a id="dd-12"></a>

## 12. PostgreSQL Uses a Dedicated Platform Tag Instead of a Tier Tag

**Context.** lxc260 runs one PostgreSQL instance for consumers in different tags: Paperless-ngx in
`tag:tier1` and OpenWebUI in `tag:ai-stack`.

**Decision.** lxc260 carries `tag:database`, outside the tier hierarchy. Each consumer is granted
`tag:database:5432` by its own rule.

**Rationale.** Inside a tier, intra-tier rules would give every service in that tier the database on
all ports, and consumers in other tags would need exceptions that erode the tier model. A platform
tag makes every consumer explicit by tag and port. `tag:monitoring` (DD-11) follows the same
pattern, and a future shared platform service should too.

**Implications.** One ACL rule per consumer
([tailscale-acl.md](../platform/tailscale-acl.md), Rules 5 and 6). Management reaches lxc260 over
SSH from the control node only; no workstation is granted 5432.

**Trade-offs.** More ACL maintenance per consumer, in exchange for explicit, auditable access.

---

<a id="dd-13"></a>

## 13. Standardized TUN Configuration for Tailscale-Capable LXCs

**Context.** During initial provisioning TUN was configured inconsistently: some containers lacked
the cgroup2 device rule or the mount entry, and lxc200 ran with AppArmor disabled and no capability
restrictions.

**Decision.** Every unprivileged LXC running Tailscale carries exactly this TUN configuration (the
CT210 pattern):

    lxc.cgroup2.devices.allow: c 10:200 rwm
    lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file

No permissive overrides: `lxc.apparmor.profile: unconfined` is not set, and `lxc.cap.drop:` is not
set to an empty value.

**Rationale.** Without the cgroup rule the kernel denies the TUN device whatever is mounted; without
the mount entry the device does not exist in the container. Missing either, Tailscale falls back to
userspace networking, which is harder to observe and debug. `unconfined` removes mandatory access
control for every process in the container, and an empty `cap.drop` grants maximum capabilities;
no service here needs either.

**Implications.** The CT210 pattern is the reference for new Tailscale-capable LXCs; a deviation is
justified in the node document. Onboarding checks the TUN configuration.
