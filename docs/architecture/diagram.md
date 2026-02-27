# Infrastructure Architecture – Logical View

This diagram shows the logical separation of layers, storage dependencies, and the access model:

- Remote access: Tailscale overlay for all services
- LAN access: only media services on VM100 (performance trade-off)
- No public ingress: no router port-forwarding / no public reverse proxy

```mermaid
flowchart TB

  %% Access Layers
  Internet((Internet))
  LAN((Local Network))
  TS[Tailscale Overlay - Zero Trust]
  NoPublic[No Public Ingress<br/>no port-forwarding / no public reverse proxy]

  Internet --> NoPublic
  NoPublic -.-> TS

  %% Proxmox Layer
  subgraph Proxmox Host
    VM102[VM102 - Storage<br/>SnapRAID + MergerFS + Samba]
    VM100[VM100 - GPU / Compute<br/>Docker + NVIDIA]
    LXC200[LXC200 - Monitoring<br/>Prometheus + Grafana]
    LXC210[LXC210 - Nextcloud<br/>Apache + PHP + MariaDB + Redis]
    LXC212[LXC212 - Calibre-Web<br/>Docker]
    LXC230[LXC230 - Vaultwarden<br/>Docker]
  end

  %% Storage Internals
  Disks[(Data Disks)]
  Parity[(Parity Disk)]
  MergerFS[/mnt/mergerfs/]
  Samba[SMB Shares - segmented]

  Disks --> MergerFS
  Parity --> MergerFS
  MergerFS --> Samba
  VM102 --> MergerFS
  VM102 --> Samba

  %% Storage Consumers
  Samba --> VM100
  Samba --> LXC210
  Samba --> LXC212
  Samba --> LXC230

  %% VM100 Services
  VM100 --> Jellyfin[Jellyfin]
  VM100 --> ABS[Audiobookshelf]

  %% Monitoring Targets
  LXC200 --> VM102
  LXC200 --> VM100
  LXC200 --> LXC210
  LXC200 --> LXC212
  LXC200 --> LXC230

  %% Access Model
  TS --> VM100
  TS --> VM102
  TS --> LXC200
  TS --> LXC210
  TS --> LXC212
  TS --> LXC230

  LAN --> Jellyfin
  LAN --> ABS

  TS --> Jellyfin
  TS --> ABS

```

Note: Network policy is enforced via Tailscale ACL (tags + ACL JSON). See: [docs/platform/tailscale-acl.md](../platform/tailscale-acl.md)
