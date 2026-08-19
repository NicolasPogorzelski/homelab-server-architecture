# Infrastructure Architecture - Logical View

Three views, each answering one question: who may talk to whom, where the bytes live, and what is
watched. Two further views live in their own documents because they answer questions about failure
rather than about structure - [failure domains](failure-domains.md) and
[backup and recovery](backup-flow.md).

## Reading the arrows

**An arrow follows what is delivered.** A request to the service it reaches, bytes to the node that
consumes them, metrics to the collector, configuration to the node it configures. Where the network
connection is opened in the opposite direction, the view says so on the spot - View 3 is the case
that matters, because Prometheus pulls.

A dotted arrow marks a relationship that delivers nothing: parity protection, or a path that is
deliberately absent.

**Containment means "runs inside".** Where a component runs within another, it is drawn inside its
box rather than attached by an arrow, so that no arrow has to mean "is part of" as well.

Node identifiers match the inventory (`vm100`, `lxc210`), so a node in a diagram can be grepped for
in `ansible/inventory/` and in `docs/nodes/`.

---

## View 1 - Access policy

Not a node list - the policy itself. Nodes are grouped by their Tailscale tag, and every arrow is an
ACL rule from [`tailscale-acl.md`](../platform/tailscale-acl.md) with the ports it grants. Here the
delivery direction and the connection direction are the same: the arrow is the request.

Two properties are visible only as absences. Nothing points at `tag:client` or `tag:untrusted` -
not even `tag:admin`, which reaches every infrastructure tag but no user device. And no arrow leaves
`tag:database`: lxc260 answers, it never initiates.

An ACL is a relation between sources and destinations, so it is drawn as one: sources on the left,
destinations on the right, ports on the edge. It is split in two because the policy answers two
different questions - what a person or device may reach, and what a service may reach on its own
behalf. A tag that appears in both halves is still one tag.

### 1a - Access by people and devices

```mermaid
flowchart LR
  accTitle: Tailscale ACL - access granted to operator, hypervisor, client and untrusted tags
  accDescr: Four source tags on the left with the destination tags and ports each may reach.

  ADMIN_S["tag:admin<br/>operator devices, lxc250"]
  TIER0_S["tag:tier0<br/>Proxmox host"]
  CLIENT_S["tag:client<br/>trusted user devices"]
  UNTRUST_S["tag:untrusted<br/>household TVs"]

  FULL["every infrastructure and service tag<br/>tier0, tier1, tier2, ai-stack,<br/>database, storage, monitoring"]
  ADMIN_D["tag:admin"]
  T1_D["tag:tier1<br/>lxc210, lxc211, lxc220, lxc240"]
  AI_D["tag:ai-stack<br/>lxc230"]
  T2_D["tag:tier2<br/>vm100"]

  ADMIN_S ==>|"all ports"| FULL
  ADMIN_S ==>|"all ports"| ADMIN_D
  TIER0_S ==>|"all ports"| FULL
  CLIENT_S -->|"443"| T1_D
  CLIENT_S -->|"443"| AI_D
  CLIENT_S -->|"8096, 13378"| T2_D
  UNTRUST_S -->|"8096, 13378"| T2_D

  classDef src fill:#0b3d6b,stroke:#062a4b,color:#ffffff
  classDef dst fill:#1f6f43,stroke:#14512f,color:#ffffff
  classDef untrust fill:#7a1f1f,stroke:#571414,color:#ffffff
  class ADMIN_S,TIER0_S,CLIENT_S src
  class FULL,ADMIN_D,T1_D,T2_D,AI_D dst
  class UNTRUST_S untrust
```

`tag:tier0` reaches the same set as `tag:admin`, with one difference the two separate arrows carry:
admin may also reach admin, which is what lets the operator workstation and lxc250 talk to each
other, and the hypervisor may not.

### 1b - Service to service, and monitoring

```mermaid
flowchart LR
  accTitle: Tailscale ACL - service-to-service and monitoring rules
  accDescr: Service tags and the monitoring tag on the left with the ports they may reach on storage, database, media and operator tags.

  T1_S["tag:tier1"]
  T2_S["tag:tier2"]
  AI_S["tag:ai-stack"]
  MON_S["tag:monitoring<br/>lxc200"]

  ST_D["tag:storage<br/>vm102"]
  DB_D["tag:database<br/>lxc260"]
  T2_D["tag:tier2<br/>vm100"]
  ADMIN_D["tag:admin"]
  T1_D["tag:tier1"]
  AI_D["tag:ai-stack"]
  EVERY["every tag<br/>node_exporter"]

  T1_S -->|"445"| ST_D
  T1_S -->|"5432"| DB_D
  T2_S -->|"445"| ST_D
  AI_S -->|"445"| ST_D
  AI_S -->|"5432"| DB_D
  AI_S -->|"11434"| T2_D
  AI_S -->|"11434"| ADMIN_D

  MON_S -->|"9100"| EVERY
  MON_S -->|"9187"| DB_D
  MON_S -->|"443"| T1_D
  MON_S -->|"443"| AI_D
  MON_S -->|"8096, 13378"| T2_D

  classDef src fill:#0b3d6b,stroke:#062a4b,color:#ffffff
  classDef dst fill:#1f6f43,stroke:#14512f,color:#ffffff
  class T1_S,T2_S,AI_S,MON_S src
  class ST_D,DB_D,T2_D,ADMIN_D,T1_D,AI_D,EVERY dst
```

The two monitoring rules are drawn separately on purpose. Port 9100 is node_exporter and reaches
every tag; the 443, 8096 and 13378 grants are the blackbox probes, added after
[KE-8](../platform/known-errors.md#ke-8) showed that a node can answer while the service on it is
dead. One rule measures that the machine is alive, the other that the thing people use is.

Two grants in the policy are deliberately not drawn, because drawing an unused rule as a live path
would be the sort of over-generous picture this repository keeps correcting: `tag:client:443` and
`tag:untrusted:443` both point at `tag:tier2`, and no tier2 node serves HTTPS - Calibre-Web is
`tag:tier1` by the exception noted in the ACL document. The rules exist; the paths do not.

---

## View 2 - Where the bytes live

Three storage layers, not one. The media archive is the one usually drawn, and it is the only one of
the three with parity protection. The other two carry more critical data on less protected hardware,
and both are named in open incidents.

Note the asymmetry in how the archive is reached: vm100 mounts CIFS itself, while the LXCs never do.
The Proxmox host mounts the shares and bind-mounts them into the containers, which is why a failed
host mount surfaces inside a container as an empty directory
([KE-15](../platform/known-errors.md#ke-15)).

```mermaid
flowchart TB
  accTitle: The three storage layers of the platform
  accDescr: Boot SSD thin pool with all guest root disks, aux-disk with Docker data roots, and the vm102 archive pool with parity, showing which consumer uses which.

  subgraph boot["boot SSD - scsi 9:0:0:0, behind the LSI SAS2008 HBA"]
    THIN[("pve-data thin pool")]
    PVEROOT[("pve-root, /boot/efi")]
  end

  subgraph aux["aux-disk - /mnt/aux-disk, AHCI, storage appdata_aux-disk"]
    DOCKERROOTS[("Docker data-roots<br/>lxc200, lxc211, lxc220, lxc230, lxc260")]
    JELLYRAW[("vm100 scsi1 - jellyfin-data raw image")]
  end

  subgraph pool["vm102 archive pool - disks passed through from the host by-id"]
    DISKS[("disk01 - disk05 + aux-pool")]
    PARITY[("parity1 - outside the union")]
    MERGER["/mnt/mergerfs union"]
    SAMBA["Samba - segmented shares"]
  end

  THIN -->|"every VM and LXC root disk"| GUESTS["11 guests<br/>including lxc210's MariaDB and lxc250's vault password"]
  DISKS --> MERGER
  DISKS -.->|"parity covers the data disks"| PARITY
  MERGER --> SAMBA
  SAMBA -->|"CIFS, mounted by vm100 itself"| VM100["vm100"]
  SAMBA -->|"CIFS, mounted by the host"| HOSTCIFS["Proxmox CIFS mounts<br/>bind-mounted into the containers"]
  HOSTCIFS -->|"application data"| CIFSLXC["lxc210, lxc211, lxc220,<br/>lxc230, lxc240, lxc260"]
  DOCKERROOTS -->|"Docker engine state"| DOCKERLXC["lxc200, lxc211, lxc220,<br/>lxc230, lxc260"]
  JELLYRAW --> VM100

  classDef sick fill:#7a1f1f,stroke:#571414,color:#ffffff
  classDef ok fill:#6a4a9c,stroke:#4c3570,color:#ffffff
  classDef consumer fill:#1f6f43,stroke:#14512f,color:#ffffff
  class THIN,PVEROOT,DOCKERROOTS,JELLYRAW sick
  class DISKS,PARITY,MERGER,SAMBA ok
  class GUESTS,VM100,CIFSLXC,DOCKERLXC,HOSTCIFS consumer
```

The two container groups at the bottom are deliberately not the same set. Six containers receive
application data over the host's CIFS mounts; five keep their Docker engine state on aux-disk. Four
appear in both, lxc200 only in the second, lxc210 and lxc240 only in the first - which is why a
question like "what does this container lose if that disk dies" has to be asked per node rather than
per container class.

Red marks hardware with an open fault rather than a design flaw: the boot SSD throws intermittent
transport-layer I/O errors ([KE-14](../platform/known-errors.md#ke-14), root cause unconfirmed), and
aux-disk holds 7680 unreadable sectors and is awaiting replacement
([KE-13](../platform/known-errors.md#ke-13)). What each of them takes down if it goes is the subject
of [failure domains](failure-domains.md).

---

## View 3 - Monitoring coverage

Prometheus on lxc200 with 14 scrape jobs over 19 targets, one of which is Prometheus scraping
itself and is not drawn. The arrows follow the metrics, which is the delivery direction. The
connection is opened the other way, because Prometheus pulls - View 1 shows that direction, as the
monitoring tag reaching outward on ports 9100, 9187 and the probe ports.

Coverage is drawn by exporter class rather than as one uniform arrow, because it is not uniform.

```mermaid
flowchart LR
  accTitle: Monitoring coverage by exporter class
  accDescr: node_exporter, postgres_exporter and blackbox probes delivering metrics to Prometheus on lxc200, with the two coverage gaps marked.

  subgraph targets["node_exporter - systemd binary with --collector.systemd"]
    HOST["Proxmox host<br/>+ textfile: smart.prom, lvm-thin.prom"]
    VM102["vm102<br/>+ textfile: snapraid_sync, snapraid_scrub"]
    VM100["vm100"]
    NODES["lxc210, lxc211, lxc220,<br/>lxc230, lxc240, lxc260"]
  end

  LXC200SELF["lxc200 node_exporter<br/>Docker container on loopback<br/>cannot see the host's systemd units"]
  PGEXP["postgres_exporter on lxc260<br/>pg_stat via loopback"]
  BLACKBOX["blackbox_exporter probes<br/>2 HTTP + 5 Serve-HTTPS endpoints"]
  LXC250["lxc250<br/>runs node_exporter on *:9100<br/>in no inventory group, scraped by nobody"]

  PROM["Prometheus + Alertmanager on lxc200"]

  targets -->|"metrics"| PROM
  LXC200SELF -->|"metrics, no systemd units"| PROM
  PGEXP -->|"metrics"| PROM
  BLACKBOX -->|"probe results"| PROM
  LXC250 -.->|"no scrape target exists"| PROM

  classDef ok fill:#1f6f43,stroke:#14512f,color:#ffffff
  classDef partial fill:#8a5a00,stroke:#5f3e00,color:#ffffff
  classDef gap fill:#7a1f1f,stroke:#571414,color:#ffffff
  class HOST,VM102,VM100,NODES,PGEXP,BLACKBOX ok
  class LXC200SELF partial
  class LXC250 gap
  class PROM ok
```

The two gaps are different in kind, which is why they are drawn differently. lxc200 is scraped -
its own exporter runs as a Docker container on loopback - but a container cannot see the host's
systemd units, so `SystemdUnitFailed` covers everything on that node except the node itself. lxc250
is not scraped at all: it belongs to no inventory group, the template renders no target for it, and
the exporter it does run binds `*:9100` and is read by nobody. Both are tracked in the
[remediation plan](../platform/remediation-plan.md).

Note also what the blackbox probes add. `NodeDown` says a node answers; a probe says the service on
it answers. The first run of these probes found Paperless and OpenWebUI returning 502 behind a
healthy node ([KE-8](../platform/known-errors.md#ke-8)).

---

Network policy is enforced through the Tailscale ACL, not through what these diagrams draw. The
policy document is [`tailscale-acl.md`](../platform/tailscale-acl.md); where the two disagree, the
ACL JSON in the admin console is the source of truth and this page is wrong.
