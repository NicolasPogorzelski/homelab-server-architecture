# Infrastructure Architecture - Logical View

This diagram shows the logical separation of layers, storage dependencies, and the access model:

- Remote access: Tailscale overlay for all services
- LAN access: only media services on VM100 (performance trade-off)
- No public ingress: no router port-forwarding / no public reverse proxy. Note the qualification
  in [the exposure model](exposure-diagram.md): several services bind wildcard addresses on nodes
  that carry a routable IPv6, so what prevents reachability is the router, not the binding.

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
    LXC211[LXC211 - Paperless-ngx<br/>Docker + OCR]
    LXC220[LXC220 - Calibre-Web<br/>Docker]
    LXC230[LXC230 - OpenWebUI<br/>Docker + AI Stack]
    LXC240[LXC240 - Vaultwarden<br/>Docker]
    LXC250[LXC250 - DevOps<br/>Git + Ansible + IaC]
    LXC260[LXC260 - PostgreSQL<br/>Platform Database]
  end

  %% Storage Internals
  Disks[(Data Disks)]
  Parity[(Parity Disk<br/>outside the union)]
  MergerFS[/mnt/mergerfs/]
  Samba[SMB Shares - segmented]
  HostCIFS[Proxmox CIFS mounts<br/>bind-mounted into the LXCs]

  Disks --> MergerFS
  Disks -.parity covers.-> Parity
  MergerFS --> Samba
  VM102 --> MergerFS
  VM102 --> Samba

  %% Storage Consumers
  %% VM100 mounts CIFS itself; the LXCs do not - the host mounts and binds in.
  Samba --> VM100
  Samba --> HostCIFS
  HostCIFS --> LXC210
  HostCIFS --> LXC211
  HostCIFS --> LXC220
  HostCIFS --> LXC230
  HostCIFS --> LXC240
  HostCIFS --> LXC260

  %% Database Dependency
  LXC230 --> LXC260
  LXC211 --> LXC260

  %% VM100 Services
  VM100 --> Jellyfin[Jellyfin]
  VM100 --> ABS[Audiobookshelf]
  VM100 --> Ollama[Ollama]
  LXC230 --> Ollama

  %% Monitoring Targets - LXC250 is absent on purpose: it is in no inventory group
  %% and therefore in no scrape config. That gap is the point, not an omission.
  LXC200 --> Host[Proxmox Host]
  LXC200 --> VM102
  LXC200 --> VM100
  LXC200 --> LXC210
  LXC200 --> LXC211
  LXC200 --> LXC220
  LXC200 --> LXC230
  LXC200 --> LXC240
  LXC200 --> LXC260

  %% Access Model
  TS --> VM100
  TS --> VM102
  TS --> LXC200
  TS --> LXC210
  TS --> LXC211
  TS --> LXC220
  TS --> LXC230
  TS --> LXC240
  TS --> LXC250
  TS --> LXC260

  LAN --> Jellyfin
  LAN --> ABS

  TS --> Jellyfin
  TS --> ABS

```

Note: Network policy is enforced via Tailscale ACL (tags + ACL JSON). See: [docs/platform/tailscale-acl.md](../platform/tailscale-acl.md)
