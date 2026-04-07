
## Context

All self-hosted services require remote access for a single operator.
The strategic decision to use Tailscale as Zero-Trust overlay is documented in
[Design Decisions #4](design-decisions.md#4-zero-trust-overlay-tailscale-instead-of-public-reverse-proxy).

This document addresses the **implementation pattern**: how services are bound and exposed
within that framework.

### Operational Constraints

- Single operator — no team, no on-call rotation
- Maintenance budget must remain sustainable alongside full-time studies
- No public-facing services required (no multi-user, no external APIs)
- All access exclusively within the Tailnet (no Funnel)

---

## Decision

Every service binds exclusively to `127.0.0.1` (loopback) on its configured port.
Tailscale Serve acts as the reverse proxy: it terminates TLS on the Tailscale interface
and forwards traffic to the local loopback port via HTTP.

### Pattern

```
Client (Tailnet) → Tailscale Serve (HTTPS, :443/:8443/...) → 127.0.0.1:<port> (HTTP)
```

### Example: Grafana on LXC200

```bash
# Grafana binds to loopback only (docker-compose.yml)
ports:
  - "127.0.0.1:3000:3000"

# Tailscale Serve exposes it on the Tailscale interface
tailscale serve --bg --https=443 http://127.0.0.1:3000
```

- The service is unreachable from LAN (not bound to `0.0.0.0` or the LAN interface)
- The service is unreachable from the internet (no port-forwarding, no Funnel)
- Only authenticated Tailnet members can reach it

---

## Alternatives Considered

### Nginx / Caddy as Reverse Proxy

A traditional reverse proxy (Nginx, Caddy, Traefik) was evaluated conceptually but not tested.
No hands-on experience exists with any of these tools at the time of writing.

Reasons for not choosing this path:

- Requires manual TLS certificate management (Let's Encrypt renewal, DNS challenges)
- Requires firewall rule maintenance and port-forwarding at the router
- Adds a service dependency that must itself be monitored and updated
- Significant configuration surface (virtual hosts, upstream blocks, reload handling)
- Operational overhead disproportionate for a single-operator homelab
- Learning curve for a tool that is not needed for the current use case

Tailscale Serve eliminates all of these: TLS is automatic, authentication is implicit,
and no ports are opened to the internet.

**Competency gap acknowledged:** Nginx, Traefik, and HAProxy are industry standard
in professional environments. Hands-on experience with at least one traditional reverse proxy
is planned after the core homelab infrastructure is complete — as a dedicated learning exercise,
separate from production infrastructure.

### Direct Binding to Tailscale IP (100.x.y.z)

Binding services directly to the Tailscale interface IP was considered:

- Removes the need for Tailscale Serve entirely
- But: no TLS termination (services would need to handle TLS themselves)
- IP can change if the node is re-registered
- No centralized access logging via `tailscale serve status`
- Harder to reason about — loopback-only is a clearer security boundary

### Traefik with Docker Integration

Traefik's automatic container discovery was considered:

- Powerful for multi-service Docker hosts
- But: adds significant complexity (labels, entrypoints, middleware)
- Overkill for the current number of services
- Would require Traefik-specific knowledge that doesn't transfer 1:1

---

## Implementation Rules

| Rule | Rationale |
|---|---|
| Always bind to `127.0.0.1`, never `0.0.0.0` | Prevents unintended LAN/WAN exposure |
| One service per Tailscale Serve port | Tailscale Serve does not support subpath routing |
| Backend protocol is always `http://` | Tailscale Serve terminates TLS; the backend must not use HTTPS |
| No Funnel | All access restricted to authenticated Tailnet members |
| Document port assignments per node | Prevents port collisions, enables traceability |

### Current Port Assignments

#### Nodes with Loopback + Tailscale Serve (pattern fully implemented)

| Node | Service | Loopback Port | Tailscale Serve Port | Hostname |
|---|---|---|---|---|
| LXC200 | Grafana | 3000 | 443 | monitoring.<tailnet-id>.ts.net |
| LXC200 | Prometheus | 9090 | 9443 | monitoring.<tailnet-id>.ts.net:9443 |
| LXC211 | Paperless-ngx | 8000 | 443 | paperless.<tailnet-id>.ts.net |
| LXC220 | Calibre-Web | 8083 | 443 | calibreweb.<tailnet-id>.ts.net |
| LXC230 | OpenWebUI | 3000 | 443 | ai-openwebui.<tailnet-id>.ts.net |
| LXC240 | Vaultwarden | 8080 | 443 | vaultwarden.<tailnet-id>.ts.net |

#### Documented Exceptions (no Tailscale Serve, `0.0.0.0` binding)

| Node | Service | Bind Address | Port | Reason |
|---|---|---|---|---|
| VM100 | Jellyfin | 0.0.0.0 | 8096 | LAN streaming, bandwidth trade-off (see [DD#8](design-decisions.md#8-lan-exposure-for-performance-critical-workloads)) |
| VM100 | Audiobookshelf | 0.0.0.0 | 13378 | LAN streaming, bandwidth trade-off (see [DD#8](design-decisions.md#8-lan-exposure-for-performance-critical-workloads)) |
| LXC210 | Nextcloud | 0.0.0.0 | 80, 443 | LAN upload performance for large data volumes; Apache-managed TLS |

#### Nodes Without Web Services

| Node | Reason |
|---|---|
| LXC250 | DevOps workstation, SSH access only |
| CT260 | PostgreSQL platform service, Tailscale IP binding only (port 5432) |

#### Notes on Exceptions

VM100 and LXC210 intentionally do not follow the loopback pattern.
The reason in both cases is performance:

- **VM100 (Media):** High-bitrate streams over LAN avoid the Tailscale overhead.
  Remote access currently uses the Tailscale IP directly (HTTP, no TLS).
  Tailscale Serve could be added later to provide TLS-secured remote access with a hostname,
  without removing the LAN binding — this would require keeping the `0.0.0.0` bind instead of `127.0.0.1`.
  Not prioritized at this time (convenience improvement, not a security improvement — see section below).
- **LXC210 (Nextcloud):** Uploading large data volumes (e.g. multi-GB PDFs) over LAN
  is significantly faster than routing through the Tailscale overlay. Apache handles TLS termination
  on port 443 — LAN access is therefore also encrypted. Tailscale Serve is not in use here.
  Nextcloud is still reachable via `nextcloud.<tailnet-id>.ts.net` — MagicDNS resolves the hostname
  to the Tailscale IP, and Apache answers the request directly (no Tailscale Serve involved).

#### Security Assessment of Exceptions

Important clarification: even without Tailscale Serve, remote access via Tailscale is protected.

Tailscale establishes a **WireGuard tunnel** between all nodes. All traffic over
Tailscale IPs (`100.x.y.z`) is encrypted at the network level — regardless of whether
the service itself speaks HTTP or HTTPS.

| Access Path | Encryption | Example |
|---|---|---|
| LAN → VM100 (HTTP) | None (cleartext on LAN) | `http://192.168.x.x:8096` |
| Tailscale → VM100 (HTTP) | WireGuard tunnel (encrypted) | `http://100.x.y.z:8096` |
| LAN → LXC210 (HTTPS) | Apache TLS (encrypted) | `https://192.168.x.x` |
| Tailscale → LXC210 (HTTPS) | WireGuard + Apache TLS (double) | `https://nextcloud.<tailnet-id>.ts.net` |

The absence of Tailscale Serve on VM100 means: no TLS certificate, no MagicDNS HTTPS hostname.
This is a convenience gap, not a security gap. The WireGuard encryption protects the traffic.

With sufficient upstream bandwidth (~500 Mbit, see DD#9), LAN exposure will be reduced
and a more consistent model adopted.

---

## Known Pitfalls

### 1. HTTPS → HTTP Mismatch

**Symptom:** Tailscale Serve returns a TLS error or connection refused.

**Cause:** `tailscale serve` was configured with `https://127.0.0.1:...` as backend,
but the service only speaks HTTP on loopback.

**Fix:**
```bash
# Remove the misconfigured serve entry
tailscale serve off
# Re-add with correct http:// backend
tailscale serve --bg --https=<port> http://127.0.0.1:<backend-port>
```

- `serve off` — removes all active serve configurations on this node
- `--bg` — runs the serve process in the background (persists after terminal close)
- `--https=<port>` — the port Tailscale Serve listens on externally (TLS-terminated)
- `http://...` — the backend target; must be `http://` because the local service does not speak TLS

### 2. One Service per Port

**Symptom:** Second service on the same Tailscale Serve port overwrites the first.

**Cause:** Tailscale Serve does not support subpath routing
(`/grafana` → Service A, `/prometheus` → Service B does not work).

**Fix:** Assign each service a unique port and document it in the port table above.

### 3. Serve Configuration: Persistence Behavior

**Observation (as of March 2026):** Serve configurations have remained persistent
across individual LXC/VM reboots. A full Proxmox host reboot (all nodes simultaneously)
has not yet been performed.

**Verification after restart:**
```bash
tailscale serve status
```

- `serve status` — shows all currently active serve configurations on this node

If empty: re-run the serve commands. Long-term, automate via systemd or Ansible.

**Open item:** Perform a full host reboot test and document persistence behavior.

---

## Maintenance Overhead Assessment

### What Tailscale Serve Eliminates (vs. Traditional Reverse Proxy)

- TLS certificate management (no Let's Encrypt, no DNS challenges)
- Firewall rule maintenance (no open ports, no port-forwarding)
- Reverse proxy configuration (no nginx.conf, no Caddyfile)
- No DNS records required for services

### What Remains

- Tailscale Serve must be configured per service (one-time)
- Port assignments must be documented
- Serve status should be verified after node restarts
- Tailscale client updates across all nodes

### Vendor Lock-in Awareness

Tailscale is a central component of the infrastructure. Risks:

- Changes to the free tier could restrict features
- Coordination server outage prevents new connections
  (existing connections via DERP remain temporarily functional)
- No trivial fallback to an alternative VPN without architectural changes

**Assessment:** Acceptable for a single-operator homelab.
The decision saves significant maintenance time, which is invested in competency building (Ansible, IaC).
A migration scenario (e.g. to Headscale or direct WireGuard) is deliberately not prepared,
but the loopback binding convention remains valuable even without Tailscale.

---

## Trade-offs

| Advantage | Limitation |
|---|---|
| No TLS management | Vendor dependency (Tailscale) |
| No open ports | No subpath routing possible |
| Implicit authentication | Each service requires its own port |
| Minimal maintenance overhead | Less learning effect for traditional reverse proxy setups |
| Clear security model | Serve persistence after full host reboot not yet verified |
| Consistent pattern for new services | Performance exceptions (VM100, LXC210) require separate documentation |

---

## Related Documents

- [Design Decisions #4: Zero-Trust Overlay](design-decisions.md#4-zero-trust-overlay-tailscale-instead-of-public-reverse-proxy)
- [Design Decisions #8/#9: LAN Exposure](design-decisions.md#8-lan-exposure-for-performance-critical-workloads)
- [Tailscale ACL Model](../platform/tailscale-acl.md)
- [Networking](../platform/networking.md)
