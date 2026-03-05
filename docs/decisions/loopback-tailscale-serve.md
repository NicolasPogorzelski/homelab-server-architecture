# Decision: Loopback-Only Binding + Tailscale Serve as Reverse Proxy

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

#### Nodes mit Loopback + Tailscale Serve (Pattern vollständig umgesetzt)

| Node | Service | Loopback Port | Tailscale Serve Port | Hostname |
|---|---|---|---|---|
| LXC200 | Grafana | 3000 | 443 | monitoring.<tailnet-id>.ts.net |
| LXC200 | Prometheus | 9090 | 9443 | monitoring.<tailnet-id>.ts.net:9443 |
| LXC220 | Calibre-Web | 8083 | 443 | calibreweb.<tailnet-id>.ts.net |
| LXC240 | Vaultwarden | 8080 | 443 | vaultwarden.<tailnet-id>.ts.net |

#### Dokumentierte Ausnahmen (kein Tailscale Serve, `0.0.0.0` Binding)

| Node | Service | Bind Address | Port | Grund |
|---|---|---|---|---|
| VM100 | Jellyfin | 0.0.0.0 | 8096 | LAN-Streaming, Bandbreiten-Trade-off (siehe DD#8) |
| VM100 | Audiobookshelf | 0.0.0.0 | 13378 | LAN-Streaming, Bandbreiten-Trade-off (siehe DD#8) |
| LXC210 | Nextcloud | 0.0.0.0 | 80, 443 | LAN-Upload-Performance für große Datenmengen; Apache-eigenes TLS |

#### Nodes ohne Web-Services

| Node | Grund |
|---|---|
| LXC250 | DevOps-Workstation, nur SSH-Zugriff |
| LXC230 | Noch nicht eingerichtet (OpenWebUI geplant) |

#### Hinweis zu den Ausnahmen

VM100 und LXC210 folgen bewusst nicht dem Loopback-Pattern.
Der Grund ist in beiden Fällen Performance:

- **VM100 (Media):** Hochbitratige Streams über LAN vermeiden den Tailscale-Overhead.
  Remote-Zugriff erfolgt aktuell über die Tailscale-IP direkt (HTTP, kein TLS).
  Tailscale Serve könnte nachgerüstet werden, um Remote-Zugriff mit TLS-Hostname zu ermöglichen,
  ohne das LAN-Binding aufzugeben — das erfordert dann Binding auf `0.0.0.0` statt `127.0.0.1`.
  Aktuell nicht priorisiert (Komfortgewinn, kein Sicherheitsgewinn — siehe Abschnitt unten).
- **LXC210 (Nextcloud):** Upload großer Datenmengen (z.B. mehrere GB PDFs) über LAN
  ist deutlich schneller als über das Tailscale-Overlay. Apache übernimmt TLS-Terminierung
  selbst auf Port 443 — damit ist auch LAN-Zugriff verschlüsselt. Tailscale Serve ist hier nicht im Einsatz.
  Nextcloud ist trotzdem über `nextcloud.<tailnet-id>.ts.net` erreichbar — MagicDNS löst den Hostnamen
  auf die Tailscale-IP auf, und Apache beantwortet die Anfrage direkt (kein Tailscale Serve beteiligt).

#### Sicherheitsbewertung der Ausnahmen

Wichtige Klarstellung: Auch ohne Tailscale Serve ist der Remote-Zugriff über Tailscale geschützt.

Tailscale baut zwischen allen Nodes einen **WireGuard-Tunnel** auf. Jeglicher Traffic über
Tailscale-IPs (`100.x.y.z`) ist auf Netzwerkebene verschlüsselt — unabhängig davon,
ob der Service selbst HTTP oder HTTPS spricht.

| Zugriffsweg | Verschlüsselung | Beispiel |
|---|---|---|
| LAN → VM100 (HTTP) | Keine (Klartext im LAN) | `http://192.168.x.x:8096` |
| Tailscale → VM100 (HTTP) | WireGuard-Tunnel (verschlüsselt) | `http://100.x.y.z:8096` |
| LAN → LXC210 (HTTPS) | Apache-TLS (verschlüsselt) | `https://192.168.x.x` |
| Tailscale → LXC210 (HTTPS) | WireGuard + Apache-TLS (doppelt) | `https://nextcloud.<tailnet-id>.ts.net` |

Der fehlende Tailscale Serve auf VM100 bedeutet: kein TLS-Zertifikat, kein MagicDNS-HTTPS-Hostname.
Das ist ein Komfort-Defizit, kein Sicherheits-Defizit. Die WireGuard-Verschlüsselung schützt den Traffic.

Perspektivisch (siehe DD#9) soll bei ausreichender Upstream-Bandbreite (~500 Mbit)
die LAN-Exposition reduziert und ein konsistenteres Modell angestrebt werden.

---

## Known Pitfalls

### 1. HTTPS → HTTP Mismatch

**Symptom:** Tailscale Serve returns a TLS error or connection refused.

**Cause:** `tailscale serve` was configured with `https://127.0.0.1:...` as backend,
but the service only speaks HTTP on loopback.

**Fix:**
```bash
# Erst die fehlerhafte Konfiguration entfernen
tailscale serve off
# Dann korrekt mit http:// Backend neu hinzufügen
tailscale serve --bg --https=<port> http://127.0.0.1:<backend-port>
```

- `serve off` — entfernt alle aktiven Serve-Konfigurationen auf diesem Node
- `--bg` — startet den Serve-Prozess im Hintergrund (bleibt nach Terminal-Schließung aktiv)
- `--https=<port>` — der Port, auf dem Tailscale Serve extern lauscht (TLS-terminiert)
- `http://...` — das Backend-Ziel; muss `http://` sein, weil der lokale Service kein TLS spricht

### 2. One Service per Port

**Symptom:** Zweiter Service auf demselben Tailscale-Serve-Port überschreibt den ersten.

**Cause:** Tailscale Serve unterstützt kein Subpath-Routing
(`/grafana` → Service A, `/prometheus` → Service B` funktioniert nicht).

**Fix:** Jedem Service einen eigenen Port zuweisen und in der Port-Tabelle oben dokumentieren.

### 3. Serve-Konfiguration: Persistenz-Verhalten

**Beobachtung (Stand März 2026):** Bei einzelnen LXC/VM-Reboots blieb die Serve-Konfiguration
bisher stabil persistent. Ein vollständiger Proxmox-Host-Reboot (alle Nodes gleichzeitig)
wurde noch nicht durchgeführt.

**Prüfung nach Neustart:**
```bash
tailscale serve status
```

- `serve status` — zeigt alle aktuell aktiven Serve-Konfigurationen auf diesem Node

Falls leer: Serve-Befehle erneut ausführen. Perspektivisch über systemd oder Ansible automatisieren.

**Offener Punkt:** Vollständiger Host-Reboot als Test durchführen und Persistenz-Verhalten
dokumentieren.

---

## Wartungsaufwand-Bewertung

### Was Tailscale Serve eliminiert (vs. klassischer Reverse Proxy)

- TLS-Zertifikatsverwaltung (kein Let's Encrypt, kein DNS-Challenge)
- Firewall-Regelwartung (keine offenen Ports, kein Port-Forwarding)
- Reverse-Proxy-Konfiguration (keine nginx.conf, keine Caddyfile)
- Keine DNS-Einträge für Services notwendig

### Was bleibt

- Tailscale Serve muss pro Service eingerichtet werden (einmalig)
- Port-Assignments müssen dokumentiert werden
- Serve-Status nach Node-Neustarts prüfen
- Tailscale-Client-Updates auf allen Nodes

### Vendor-Lock-in-Bewusstsein

Tailscale ist ein zentraler Bestandteil der Infrastruktur. Risiken:

- Änderungen am Free-Tier könnten Features einschränken
- Ausfall des Coordination Servers verhindert neue Verbindungen
  (bestehende Verbindungen über DERP bleiben temporär funktional)
- Kein triviales Fallback auf alternatives VPN ohne Architekturänderung

**Bewertung:** Für ein Single-Operator-Homelab akzeptabel.
Die Entscheidung spart signifikant Wartungszeit, die in Kompetenzaufbau (Ansible, IaC) investiert wird.
Ein Migrations-Szenario (z.B. zu Headscale oder WireGuard direkt) wird bewusst nicht vorbereitet,
aber die Loopback-Binding-Konvention bleibt auch ohne Tailscale sinnvoll.

---

## Trade-offs

| Vorteil | Einschränkung |
|---|---|
| Kein TLS-Management | Vendor-Abhängigkeit (Tailscale) |
| Keine offenen Ports | Kein Subpath-Routing möglich |
| Implizite Authentifizierung | Jeder Service braucht eigenen Port |
| Minimaler Wartungsaufwand | Weniger Lerneffekt für klassische Reverse-Proxy-Setups |
| Klares Sicherheitsmodell | Serve-Persistenz nach Full-Host-Reboot noch nicht verifiziert |
| Konsistentes Pattern für neue Services | Performance-Ausnahmen (VM100, LXC210) erfordern separate Dokumentation |

---

## Related Documents

- [Design Decisions #4: Zero-Trust Overlay](design-decisions.md#4-zero-trust-overlay-tailscale-instead-of-public-reverse-proxy)
- [Design Decisions #8/#9: LAN Exposure](design-decisions.md#8-lan-exposure-for-media-workloads-performance-trade-off)
- [Tailscale ACL Model](../platform/tailscale-acl.md)
- [Networking](../platform/networking.md)
