# Infrastructure Exposure Model

This diagram shows how services are accessed and how public ingress is prevented.

```mermaid
flowchart TB

  Internet((Internet))
  LAN((Local Network))
  TS[Tailscale Overlay Network<br/>Identity-based Access]
  NoPublic[No Public Ingress<br/>No router port-forwarding]

  %% Internet access model
  Internet --> TS
  Internet --> NoPublic

  %% No direct exposure
  NoPublic -.-> Services

  subgraph Services
    Jellyfin[Jellyfin]
    ABS[Audiobookshelf]
    Nextcloud[Nextcloud]
    Vaultwarden[Vaultwarden]
    CalibreWeb[Calibre-Web]
    Monitoring[Monitoring<br/>Grafana + Prometheus]
  end

  %% LAN exposure (media only)
  LAN --> Jellyfin
  LAN --> ABS

  %% Tailscale exposure (all services)
  TS --> Jellyfin
  TS --> ABS
  TS --> Nextcloud
  TS --> Vaultwarden
  TS --> CalibreWeb
  TS --> Monitoring
