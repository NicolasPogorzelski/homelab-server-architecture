# Infrastructure Architecture - Logical View

Three views: who may reach whom, where the bytes live, and what is watched. Failure and backup have
their own views: [failure domains](failure-domains.md) and [backup and recovery](backup-flow.md).

## Reading the Arrows

An arrow follows what is delivered: a request to the service it reaches, bytes to their consumer,
metrics to the collector. Where the connection opens the other way, the view says so (View 3,
because Prometheus pulls). A dotted arrow delivers nothing: parity protection, or an exercise path.
A component drawn inside a box runs inside it. Node names match the inventory.

## View 1 - Access Policy

Every arrow is a grant from [`tailscale-acl.md`](../platform/tailscale-acl.md) with its ports; here
the arrow is the request. Most grants name a host rather than a tag, because `tag:tier1` holds three
services. A service box stands for one host, a tag box for every node carrying the tag.

### 1a - Access by people and devices

```mermaid
flowchart LR
  accTitle: Tailscale ACL - access granted to people's devices
  accDescr: Admin workstations, admin phone, end-user devices, e-book reader, a remote TV, a streaming box and an external user through machine sharing, each with the services and ports it may reach.

  ADMIN_S["tag:admin<br/>admin workstations"]
  MOBILE_S["tag:admin-mobile<br/>admin phone"]
  CLIENT_S["tag:client<br/>phone and notebook"]
  READER_S["tag:reader<br/>e-book reader"]
  UNTRUST_S["tag:untrusted<br/>remote TV"]
  PLAYER_S["tag:media-player<br/>streaming box"]
  EXTERNAL_S["external user<br/>machine sharing"]

  INFRA["host 22, 8006<br/>vm102 22, 445<br/>vm100 22<br/>lxc250 22<br/>lxc200 443, 9093, 9443"]
  PVE["host 8006"]
  NC["nextcloud 443"]
  PL["paperless 443"]
  CW["calibreweb 443"]
  OW["openwebui 443"]
  JF["vm100 8096<br/>Jellyfin"]
  ABS["vm100 13378<br/>Audiobookshelf"]

  ADMIN_S ==> INFRA
  ADMIN_S --> NC & PL & CW & OW & JF & ABS
  MOBILE_S --> PVE & NC & PL & OW & JF & ABS
  CLIENT_S --> NC & PL & JF & ABS
  CLIENT_S -.->|"notebook only"| CW
  READER_S --> CW & ABS
  UNTRUST_S --> JF
  PLAYER_S --> JF
  EXTERNAL_S --> NC & JF & ABS
```

The dotted arrow is a grant with a narrower source: the client notebook's address, not the tag.
`tag:isolated` has no rule. No rule has a person's device as destination, except the inference
backend on the admin desktop in 1b.

### 1b - Service to service, and monitoring

```mermaid
flowchart LR
  accTitle: Tailscale ACL - service-to-service, control and monitoring rules
  accDescr: The monitoring node, the control node, the hypervisor, Nextcloud, Paperless, the database and the AI stack on the left, with the ports they may reach.

  MON_S["tag:monitoring<br/>lxc200"]
  CTL_S["tag:control<br/>lxc250"]
  T0_S["tag:tier0<br/>Proxmox host"]
  NC_S["nextcloud<br/>lxc210"]
  PL_S["paperless<br/>lxc211"]
  DB_S["tag:database<br/>lxc260"]
  AI_S["tag:ai-stack<br/>lxc230"]

  SERVERS["every server tag<br/>and tag:control"]
  PROBES["nextcloud, paperless,<br/>calibreweb, openwebui 443<br/>vm100 8096, 13378, 8080"]
  ST_D["tag:storage<br/>vm102"]
  DB_D["tag:database<br/>lxc260"]
  MON_D["tag:monitoring<br/>lxc200"]
  LLM["vm100 8080<br/>admin desktop 8080"]

  MON_S -->|"9100"| SERVERS
  MON_S -->|"9187"| DB_D
  MON_S -->|"probes"| PROBES
  CTL_S ==>|"22"| SERVERS
  CTL_S -->|"9443"| MON_D
  T0_S -->|"445"| ST_D
  NC_S -->|"445"| ST_D
  PL_S -->|"5432"| DB_D
  PL_S -.->|"19532"| MON_D
  DB_S -.->|"19532"| MON_D
  AI_S -->|"5432"| DB_D
  AI_S -->|"8080"| LLM
```

The dotted arrows are the journal upload, an [exercise](../decisions/exercise-scope-before-terraform.md).
`tag:storage` and `tag:tier2` never appear as a source: vm102 and vm100 initiate nothing over the
tailnet (vm100 mounts its media over the LAN), and ACLs are deny-by-default. Port 9100 shows that a
machine is alive; the probes show that the service on it answers
([KE-8](../platform/known-errors.md#ke-8)).

## View 2 - Where the Bytes Live

Three storage layers. Only the archive pool has parity; the other two carry the root disks, the
Docker state and the PostgreSQL data on single disks, both with open faults.

vm100 mounts CIFS itself; the containers never do. The host mounts the shares and bind-mounts them
into the containers, so a failed host mount appears inside a container as an empty directory
([KE-15](../platform/known-errors.md#ke-15)).

```mermaid
flowchart TB
  accTitle: The three storage layers of the platform
  accDescr: Boot SSD thin pool with all guest root disks, aux-disk with Docker data roots, PostgreSQL data and vm100's data disk, and the vm102 archive pool with parity, showing which consumer uses which.

  subgraph boot["boot SSD - behind the LSI SAS2008 HBA"]
    THIN[("pve-data thin pool")]
    PVEROOT[("pve-root, /boot/efi")]
  end

  subgraph aux["aux-disk - /mnt/aux-disk"]
    DOCKERROOTS[("Docker data-roots<br/>lxc200, lxc211, lxc220, lxc230")]
    PGDATA[("PostgreSQL data directory<br/>lxc260")]
    JELLY[("vm100 scsi1 - jellyfin-data, qcow2")]
    VZDUMP[("/mnt/vzdump - guest backups")]
  end

  subgraph pool["vm102 archive pool - disks passed through by-id"]
    DISKS[("disk01 - disk06 + aux-pool")]
    PARITY[("parity disk - outside the union")]
    MERGER["/mnt/mergerfs union"]
    SAMBA["Samba - segmented shares"]
  end

  THIN -->|"every guest root disk"| GUESTS["9 guests<br/>including lxc210's MariaDB<br/>and lxc250's Ansible secrets"]
  DISKS --> MERGER
  DISKS -.->|"parity covers the data disks"| PARITY
  MERGER --> SAMBA
  SAMBA -->|"CIFS, mounted by vm100 itself"| VM100["vm100"]
  SAMBA -->|"CIFS, mounted by the host"| HOSTCIFS["Proxmox CIFS mounts<br/>bind-mounted into containers"]
  HOSTCIFS -->|"application data, dumps"| CIFSLXC["lxc210, lxc211,<br/>lxc220, lxc260"]
  DOCKERROOTS -->|"Docker engine state"| DOCKERLXC["lxc200, lxc211,<br/>lxc220, lxc230"]
  PGDATA --> PG["lxc260"]
  JELLY --> VM100

  classDef sick fill:#7a1f1f,stroke:#571414,color:#ffffff
  classDef ok fill:#6a4a9c,stroke:#4c3570,color:#ffffff
  classDef consumer fill:#1f6f43,stroke:#14512f,color:#ffffff
  class THIN,PVEROOT,DOCKERROOTS,PGDATA,JELLY,VZDUMP sick
  class DISKS,PARITY,MERGER,SAMBA ok
  class GUESTS,VM100,CIFSLXC,DOCKERLXC,HOSTCIFS,PG consumer
```

The two container groups differ: lxc210 and lxc260 receive CIFS data but run no Docker; lxc200 and
lxc230 run Docker but have no CIFS mount. Loss per disk is therefore asked per node.

Red marks hardware with an open fault: the boot SSD logs transport-layer I/O errors
([KE-14](../platform/known-errors.md#ke-14)), and the aux-disk has a growing count of unreadable
sectors ([KE-13](../platform/known-errors.md#ke-13)). See [failure domains](failure-domains.md).

## View 3 - Monitoring Coverage

Prometheus on lxc200 scrapes the jobs rendered from
`ansible/roles/prometheus_config/templates/prometheus.yml.j2`. Metrics flow to lxc200; the connection
opens the other way, as the monitoring grants in View 1.

| Exporter | Where | Adds |
|---|---|---|
| node_exporter, systemd unit on the Tailscale address | every node | `node_systemd_unit_state`, apt and listener metrics |
| textfile collectors | host, vm102, vm100 | SMART, LVM thin pool, guest and host-config backup; SnapRAID, storage permissions; CUDA watchdog |
| node_exporter, Docker container on loopback | lxc200 | resources only, no systemd units |
| postgres_exporter | lxc260 | `pg_stat_*`, `pg_up` |
| blackbox_exporter | lxc200 | three HTTP probes on vm100, four HTTPS probes behind `tailscale serve` |

`SystemdUnitFailed` covers all ten nodes. On lxc200 the container exporter cannot see the node's
systemd, so a second, native exporter on 9101 reports it
([decision](../decisions/lxc200-systemd-visibility.md)).

The policy is enforced by the Tailscale ACL, not by these diagrams. Where they disagree with the
admin console, the console is the source of truth.
