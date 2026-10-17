# Services Bind Loopback and Are Published by Tailscale Serve

## Status
Implemented. Decided 2026-03-05. Supersedes / superseded by: -.

Verified 2026-10-02: after the cold boot that morning every serve configuration was back without
intervention; `tailscaled` keeps it in its state file, and the host powers down nightly, so every
boot repeats the test.

## Context
Remote access runs over Tailscale ([DD-4](design-decisions.md#dd-4)); nothing is published to the
internet and no service is meant to answer on the LAN. This record decides how a service is bound
and exposed inside that model. Constraints: no public-facing service, no Funnel, no router port
forwarding, and maintenance kept small enough for one administrator.

## Options
- **Nginx or Caddy as reverse proxy.** Lost: certificate renewal, upstream configuration and a
  further daemon to patch and monitor, for a problem `tailscale serve` already solves.
- **Traefik with Docker labels.** Lost: label and middleware configuration sized for many services
  per Docker host; here most nodes run one.
- **Bind every service to its Tailscale address.** Lost as the default: no TLS termination, and the
  service cannot start before `tailscaled` has assigned the address
  ([KE-18](../platform/known-errors.md#ke-18)). Kept as the rule for the cases below.
- **Bind loopback and publish through `tailscale serve`.** Chosen as the default.

## Decision
A service binds `127.0.0.1` and `tailscale serve` publishes it on the node's tailnet hostname.
For HTTP services serve terminates TLS with the node's `ts.net` certificate and proxies to a plain
`http://` backend; for other protocols it forwards TCP (`--tcp`). Nothing binds a LAN address.

A service binds its Tailscale address instead when serve is not suitable, behind the
`tailscale_boot_gate` drop-in so it starts only once the address exists:

| Service | Node | Reason |
|---|---|---|
| Jellyfin | vm100 | Long high-bitrate streams stalled in serve's userspace TCP forwarder ([KE-28](../platform/known-errors.md#ke-28)) |
| PostgreSQL | lxc260 | Binary protocol; consumers connect to `<tailscale-ip-lxc260>:5432` ([boot ordering](postgresql-tailscale-boot-ordering.md)) |
| node_exporter, postgres_exporter, journal receiver | all nodes, lxc260, lxc200 | Scraped or written to directly by Prometheus and the journal senders, no TLS needed |
| sshd | all guests | [sshd decision](sshd-listen-address.md) |

Apache on lxc210 still binds the wildcard on 80 and 443; `lan_guard` closes the LAN side and moving
Nextcloud behind serve is open work ([remediation plan](../platform/remediation-plan.md)).

### Example: Grafana on lxc200

The monitoring stack runs with `network_mode: host` (`docker/monitoring/docker-compose.yml`), so
each service sets its own listen address instead of a port mapping: Prometheus through
`PROM_BIND_ADDRESS=127.0.0.1` (`docker/monitoring/.env.example`), Grafana through its environment
file, which stays outside the repository. Serve publishes them:

```bash
tailscale serve --bg --https=443  http://127.0.0.1:3000   # Grafana
tailscale serve --bg --https=9443 http://127.0.0.1:9090   # Prometheus
tailscale serve status                                    # prints the configuration above
```

### Published services

| Node | Service | Backend | Tailnet port |
|---|---|---|---|
| lxc200 | Grafana | `127.0.0.1:3000` | 443 |
| lxc200 | Prometheus | `127.0.0.1:9090` | 9443 |
| lxc200 | Alertmanager | `127.0.0.1:9093` | 9093 |
| lxc211 | Paperless-ngx | `127.0.0.1:8000` | 443 |
| lxc220 | Calibre-Web | `127.0.0.1:8083` | 443 |
| lxc230 | OpenWebUI | `127.0.0.1:3000` | 443 |
| vm100 | Audiobookshelf | `tcp://127.0.0.1:13378` | 13378 (TCP) |
| vm100 | llama-server | `tcp://127.0.0.1:8080` | 8080 (TCP) |

Per-node detail is in the node documents under `docs/nodes/`.

### Rules

| Rule | Reason |
|---|---|
| Bind `127.0.0.1` or the Tailscale address, never `0.0.0.0` or a LAN address | No LAN or internet exposure from the bind itself |
| Backend is `http://` for HTTPS publishing | Serve terminates TLS; an `https://` backend against a plain-HTTP service fails |
| One port per service on a node | `--set-path` can route sub-paths, but each application would then need its own sub-path configuration (Grafana's root URL, for example) |
| No Funnel | Only tailnet members, as the ACL grants them, reach a service |

## Consequences
- TLS, certificates and device authentication come from Tailscale: no open router port, and
  serve-backed nodes need no certificate job (`tailscale_cert` exists only for Apache on lxc210).
- The services depend on the Tailscale control plane. Established tunnels survive an outage of the
  coordination server for a while; new connections and key changes do not. Moving the control plane
  in-house is decided in [Headscale migration](headscale-migration.md); the loopback bind does not
  change with it.
- Serve configuration is set by hand on each node and lives in `tailscaled`'s state, not in the
  repository. A rebuilt node needs its serve commands from its node document.
- `tailscale serve status` shows what is configured; it records no access log. Availability is
  checked by the blackbox probes in [monitoring](../platform/monitoring.md).
- A TCP forward terminates the client connection in `tailscaled`; clients appear to the backend as
  `127.0.0.1`, and high-bitrate streams can stall there (KE-28).

## Related Documents
- [DD-4: Zero-trust overlay](design-decisions.md#dd-4)
- [Media over the tailnet](media-over-the-tailnet.md)
- [Tailscale ACL model](../platform/tailscale-acl.md)
- [Networking](../platform/networking.md)
