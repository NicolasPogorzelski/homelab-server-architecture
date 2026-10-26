# Tailscale ACL & Tagging Model

## Purpose

This platform uses Tailscale as the only remote-access path and as the identity layer for service-to-service communication.

Principles:

- LAN is not trusted
- No public ingress / no port-forwarding
- Access is identity-based and explicitly allowed
- Every grant names a port and, where a tag holds more than one service, a host
- The policy is one JSON document with tests, not ad-hoc per service

**Source of truth:** the policy in the Tailscale admin console, mirrored here
sanitized: addresses are placeholders, and people appear by role, never by name, device name or
e-mail address. Nothing synchronises the two: a change is written here, applied to the console by
hand, and the console's `tests` block rejects a policy that breaks an assertion on save. A drift
between this file and the console is found only by comparing them.

Every rule answers to one of two sources: a connection observed on a node, or a need the owner of
a device stated. Anything else is closed.

## Tier Model

Nodes are grouped by trust level and responsibility. Servers carry one tag each; people's devices
carry the tag of the role they are used in.

| Tag | Purpose | Nodes |
|---|---|---|
| `tag:tier0` | Hypervisor | Proxmox host |
| `tag:storage` | Persistent data layer | vm102 |
| `tag:tier1` | Security-critical services | lxc210 (Nextcloud), lxc211 (Paperless-ngx), lxc220 (Calibre-Web) |
| `tag:tier2` | Application services | vm100 (Jellyfin, Audiobookshelf, LLM fallback) |
| `tag:ai-stack` | AI services | lxc230 (OpenWebUI) |
| `tag:database` | Central PostgreSQL platform service | lxc260 |
| `tag:monitoring` | Observability stack | lxc200 |
| `tag:control` | Ansible control node | lxc250 |
| `tag:admin` | Admin workstations | admin notebook, admin desktop |
| `tag:admin-mobile` | Admin phone | one device |
| `tag:client` | End-user devices | a phone and a notebook |
| `tag:reader` | E-book reader | one device |
| `tag:untrusted` | A TV outside the home network, administered by nobody here | one device |
| `tag:media-player` | Streaming box at the TV: Jellyfin only | a streaming box |
| `tag:isolated` | No access at all: Mullvad-only devices and quarantine | none |

**Exception:** Calibre-Web (lxc220) is tagged `tag:tier1`, not `tag:tier2`, despite being an
application service by the table above. The tag decides little: every grant to
a tier1 service names the host, so the three tier1 services are reachable independently of each
other.

**Why lxc250 has its own tag.** The control node holds the vault password, the Ansible key and root
access to the hypervisor. Sharing a tag with the admin workstations would make it reachable from
every admin device and let it reach them. A human endpoint and an automation server are two
identities with two jobs; `tag:control` gives the control node only its own.

## Tag Ownership

All tags are owned by `autogroup:admin` (Tailscale account administrators).
Tags are assigned to nodes via the Tailscale admin console, and lxc250 advertises its own
(`tailscale up --advertise-tags=tag:control`), so a re-registration asks for the same tag.

```json
"tagOwners": {
    "tag:tier0":        ["autogroup:admin"],
    "tag:storage":      ["autogroup:admin"],
    "tag:tier2":        ["autogroup:admin"],
    "tag:tier1":        ["autogroup:admin"],
    "tag:ai-stack":     ["autogroup:admin"],
    "tag:database":     ["autogroup:admin"],
    "tag:monitoring":   ["autogroup:admin"],
    "tag:control":      ["autogroup:admin"],
    "tag:admin":        ["autogroup:admin"],
    "tag:admin-mobile": ["autogroup:admin"],
    "tag:client":       ["autogroup:admin"],
    "tag:reader":       ["autogroup:admin"],
    "tag:untrusted":    ["autogroup:admin"],
    "tag:isolated":     ["autogroup:admin"],
    "tag:media-player": ["autogroup:admin"]
}
```

## Host Aliases

Where a tag holds several services, a grant names the host instead, so that reaching one service
does not mean reaching its neighbours.

```json
"hosts": {
    "gpu-vm":         "<tailscale-ip-vm100>",
    "nextcloud":      "<tailscale-ip-lxc210>",
    "paperless":      "<tailscale-ip-lxc211>",
    "calibreweb":     "<tailscale-ip-lxc220>",
    "openwebui":      "<tailscale-ip-lxc230>",
    "bazzite":        "<tailscale-ip-admin-desktop>",
    "client-notebook": "<tailscale-ip-client-notebook>"
}
```

An alias is an address, and a node keeps its address only while it stays registered. A node that
is removed and added again gets a new one, and every rule naming its alias then points at nothing
or at a stranger. Re-read this block after any re-registration.

## ACL Rules (Sanitized)

### Rule 1 - Monitoring: scrapes and service probes

node_exporter on every server, postgres_exporter on the database, and the blackbox probes that
check the services people actually use ([KE-8](known-errors.md#ke-8)). No monitoring grant reaches
a person's device.

```json
{
    "action": "accept",
    "src":    ["tag:monitoring"],
    "dst": [
        "tag:tier0:9100", "tag:storage:9100", "tag:tier2:9100", "tag:tier1:9100",
        "tag:ai-stack:9100", "tag:database:9100", "tag:control:9100",
        "tag:database:9187",
        "gpu-vm:8096", "gpu-vm:13378", "gpu-vm:8080",
        "nextcloud:443", "paperless:443", "calibreweb:443", "openwebui:443"
    ]
}
```

`gpu-vm:8080` is the `llama-server` health probe. The admin desktop's backend is not probed: the
desktop is off much of the time, and a probe against it would page for a machine that is simply
switched off.

lxc200 also scrapes its own native exporter on its Tailscale address, port 9101; a node reaching
itself needs no rule (verified 2026-09-26).

### Rule 2 - Journal upload (exercise)

The two nodes that opt into central log collection may reach the receiver on lxc200, and nothing
else there ([exercise decision](../decisions/exercise-scope-before-terraform.md)). The rule names
the Paperless host and not `tag:tier1`, so Nextcloud and Calibre-Web cannot send.

```json
{
    "action": "accept",
    "src":    ["paperless", "tag:database"],
    "dst":    ["tag:monitoring:19532"]
}
```

### Rule 3 - Control node: SSH for Ansible, Prometheus API for the drift sweep

```json
{
    "action": "accept",
    "src":    ["tag:control"],
    "dst": [
        "tag:tier0:22", "tag:storage:22", "tag:tier2:22", "tag:tier1:22",
        "tag:ai-stack:22", "tag:database:22", "tag:monitoring:22", "tag:control:22",
        "tag:monitoring:9443"
    ]
}
```

`tag:control:22` is lxc250 reaching itself: the inventory addresses it by its Tailscale IP like
every other node.

### Rule 4 - Hypervisor: SMB from vm102

Verified 2026-10-17: the host mounts six shares from vm102, two of them over the tailnet and four
over the LAN, by `findmnt -t cifs`. On the LAN, `smb_guard` and `lan_guard` on vm102 admit the host
and vm100 only ([samba.md](samba.md)). Nothing else the host does crosses the tailnet; guests are
managed through `pct` and `qm` on the host itself.

```json
{
    "action": "accept",
    "src":    ["tag:tier0"],
    "dst":    ["tag:storage:445"]
}
```

### Rule 5 - Paperless-ngx: the platform database

The only tier1 service with a database on lxc260. Nextcloud keeps MariaDB locally, Calibre-Web uses
SQLite.

```json
{
    "action": "accept",
    "src":    ["paperless"],
    "dst":    ["tag:database:5432"]
}
```

### Rule 6 - AI stack: database and inference

OpenWebUI reaches its database and two `llama-server` backends on port 8080: the admin desktop as
primary and vm100 as fallback ([llm-inference.md](../services/llm-inference.md)).

```json
{
    "action": "accept",
    "src":    ["tag:ai-stack"],
    "dst":    ["tag:database:5432", "bazzite:8080", "gpu-vm:8080"]
}
```

Port 11434 is closed on both hosts, and the tests below assert it: nothing listens there.

### Rule 7 - Admin workstations

Derived from the workstation's own configuration and the documentation, without assuming "admin
means everything": SSH where an admin key exists (the host, vm102, vm100, lxc250), the web
interfaces, and the SMB shares the notebook mounts. The LXCs other than lxc250 carry no admin key,
only the Ansible key, so SSH to them would be an open port nobody can use; `pct exec` on the host is
the path into them.

```json
{
    "action": "accept",
    "src":    ["tag:admin"],
    "dst": [
        "tag:tier0:22", "tag:tier0:8006",
        "tag:storage:22", "tag:storage:445",
        "gpu-vm:22", "gpu-vm:8096", "gpu-vm:13378",
        "tag:control:22",
        "tag:monitoring:443", "tag:monitoring:9093", "tag:monitoring:9443",
        "nextcloud:443", "paperless:443", "calibreweb:443", "openwebui:443"
    ]
}
```

Not granted: PostgreSQL from a workstation (nothing in the repository uses it), SPICE on 3128
(consoles open in the browser through 8006), and any path between two admin devices.

### Rule 8 - Admin phone

The phone reaches the Proxmox interface, so the host can be shut down from it, and the services its
owner uses; nothing else. The Proxmox side is meant to match: a dedicated user whose role holds only
`Sys.PowerMgmt`, with a second factor, so a stolen phone can switch the host off and do nothing
more. That user does not exist yet; the login is still root's ([remediation plan](remediation-plan.md)).

```json
{
    "action": "accept",
    "src":    ["tag:admin-mobile"],
    "dst": [
        "tag:tier0:8006",
        "gpu-vm:8096", "gpu-vm:13378",
        "nextcloud:443", "paperless:443", "openwebui:443"
    ]
}
```

`openwebui:443` serves a mobile client for Open WebUI; the phone never talks to an inference
backend directly.

### Rules 9 and 10 - End-user devices

Nextcloud, Paperless-ngx, Jellyfin and Audiobookshelf from both devices; Calibre-Web from the
notebook only, requested for use ahead of time.

```json
{
    "action": "accept",
    "src":    ["tag:client"],
    "dst":    ["nextcloud:443", "paperless:443", "gpu-vm:8096", "gpu-vm:13378"]
},
{
    "action": "accept",
    "src":    ["client-notebook"],
    "dst":    ["calibreweb:443"]
}
```

### Rule 11 - E-book reader

Calibre-Web and Audiobookshelf. The device runs an Android release that no longer receives security
updates and connects only when a book is downloaded.

```json
{
    "action": "accept",
    "src":    ["tag:reader"],
    "dst":    ["calibreweb:443", "gpu-vm:13378"]
}
```

### Rule 12 - Untrusted: a TV outside the home network

"Untrusted" is a statement about device administration, not about the people: the TV stands outside
the home network, nobody here manages or patches it, and its Android release is years past its last
update. It gets Jellyfin and nothing else, and no rule anywhere lets another node reach it. Key
expiry is disabled for this device, because nobody on site could re-authenticate it; the
single grant is what carries the risk instead. The tier is not a guest-invite mechanism - devices are
tagged individually by the admin (`tagOwners: autogroup:admin`).

```json
{
    "action": "accept",
    "src":    ["tag:untrusted"],
    "dst":    ["gpu-vm:8096"]
}
```

### Rule 13 - External user, through machine sharing

One external user reaches Jellyfin, Audiobookshelf and Nextcloud Talk. vm100 and lxc210 are shared
into the user's own tailnet; the user's devices do not join this one. Tailscale's sharing
documentation: "Sharing gives the recipient access to only the shared
machine in your tailnet, and nothing else", and the shared machine stays subject to this policy. The
user's devices no longer sit in this network, cannot be added to it, and a rule written too broadly
here cannot reach them.

```json
{
    "action": "accept",
    "src":    ["<external-user-email>"],
    "dst":    ["gpu-vm:8096", "gpu-vm:13378", "nextcloud:443"]
}
```

The rule names the user's account and not `autogroup:shared`, so a later share with somebody else
does not inherit these rights. A grant to an account covers all of its devices; per-device limits
would require keeping those devices in this tailnet.

### Rule 14 - Media player: the streaming box at the TV

The streaming box gets Jellyfin over the tailnet and nothing else; media clients use the tailnet,
not the LAN ([decision](../decisions/media-over-the-tailnet.md)). It has its own tag and no
grant under `tag:isolated`, because that tag promises no access at all. Its Mullvad attribute is
bound to the device's address, not to the tag.

```json
{
    "action": "accept",
    "src":    ["tag:media-player"],
    "dst":    ["gpu-vm:8096"]
}
```

### Rule 15 - Nextcloud: the Paperless ingest shares

Nextcloud's External Storage writes uploads into two SMB shares on vm102 that land in Paperless's
consumption directory ([nextcloud.md](../services/nextcloud.md#external-storage-paperless-integration)).
The LAN path to vm102 is closed, so this grant is the only route. It names the one service, not
`tag:tier1`, and the mounts address vm102 by its full MagicDNS name, because the short name
`storage` also resolves on the LAN. The rule is not in the console
([KE-29](known-errors.md#ke-29)).

```json
{
    "action": "accept",
    "src":    ["nextcloud"],
    "dst":    ["tag:storage:445"]
}
```

### `tag:isolated` - no rule

A device carrying it can reach nothing and be reached by nothing. It exists for devices that use
the tailnet for a Mullvad exit node only, and as a quarantine tag.

## Node Attributes

### Mullvad Exit Nodes

Five devices may use Tailscale's Mullvad exit nodes: both admin workstations, the admin phone,
an end-user phone and a streaming box.

```json
"nodeAttrs": [
    {"target": ["<tailscale-ip-admin-notebook>"],   "attr": ["mullvad"]},
    {"target": ["<tailscale-ip-admin-desktop>"],    "attr": ["mullvad"]},
    {"target": ["<tailscale-ip-admin-phone>"],   "attr": ["mullvad"]},
    {"target": ["<tailscale-ip-client-phone>"],     "attr": ["mullvad"]},
    {"target": ["<tailscale-ip-streaming-box>"],    "attr": ["mullvad"]}
]
```

Verified 2026-09-26: the admin desktop used a Mullvad exit node with no `autogroup:internet` grant
in the policy, so the attribute alone is enough for Mullvad (Tailscale's own exit nodes need that
grant). The targets are addresses, which Tailscale's policy reference does not list as a
`nodeAttrs` selector (it names tags, users, groups and `*`); the form is kept because it works.
Because the targets are addresses, a target whose device is gone must be removed: a new device
receiving that address would inherit the attribute.

## Access Matrix (Summary)

Rows are sources, columns destinations. Host names in a cell mean that only that service is reached.

| Source | tier0 | storage | tier1 | tier2 (vm100) | ai-stack | database | monitoring | control |
|---|---|---|---|---|---|---|---|---|
| **monitoring** | 9100 | 9100 | 9100; 443 on all three | 9100, 8096, 13378, 8080 | 9100, 443 | 9100, 9187 | - | 9100 |
| **control** | 22 | 22 | 22 | 22 | 22 | 22 | 22, 9443 | 22 |
| **tier0** | - | 445 | - | - | - | - | - | - |
| **tier1** | - | nextcloud: 445 | - | - | - | paperless: 5432 | paperless: 19532 | - |
| **ai-stack** | - | - | - | 8080 | - | 5432 | - | - |
| **database** | - | - | - | - | - | - | 19532 | - |
| **tier2 and storage** | - | - | - | - | - | - | - | - |
| **admin** | 22, 8006 | 22, 445 | 443 on all three | 22, 8096, 13378 | 443 | - | 443, 9093, 9443 | 22 |
| **admin-mobile** | 8006 | - | nextcloud, paperless: 443 | 8096, 13378 | 443 | - | - | - |
| **client** | - | - | nextcloud, paperless: 443; calibreweb from the notebook | 8096, 13378 | - | - | - | - |
| **reader** | - | - | calibreweb: 443 | 13378 | - | - | - | - |
| **untrusted** | - | - | - | 8096 | - | - | - | - |
| **external user (shared)** | - | - | nextcloud: 443 | 8096, 13378 | - | - | - | - |
| **media-player** | - | - | - | 8096 | - | - | - | - |
| **isolated** | - | - | - | - | - | - | - | - |

Two columns are left out because every cell in them is empty for the servers: no rule targets
`tag:admin` except `ai-stack -> bazzite:8080`, and no rule targets any other device tag at all.

## Administrative Access Model

Administrative access is separated from service-to-service communication.

- People's devices are tagged by role and reach services by host and port
- The control node is a separate identity from the admin devices
- Service-to-service communication is controlled via tags, and via host aliases where a tag holds
  several services
- Break-glass access is documented and kept minimal

Note: the admin workstations have no document in `docs/nodes/`. They are documented
through their tag and through the hardening notes in the [remediation plan](remediation-plan.md).

## Service Onboarding Checklist (Network)

For every new service that must be reachable remotely or must reach other services:

1. Decide the node tag(s) for this service, and whether a host alias is needed because the tag
   already holds another service
2. Update the grant in this document and apply the same change in the admin console
3. Add a `tests` entry for the new path and for one path that must stay closed, in both places
4. Verify connectivity with a TCP probe from the source node, both directions of the claim
5. Ensure the service itself binds only to Tailscale (or loopback + Tailscale proxy)
6. Document the access model in the service doc

## Binding Rules (Zero Trust)

Default rules:

- Services must not bind to LAN interfaces unless explicitly justified
- Prefer:
  - bind to Tailscale IP (service listens directly on tailnet), or
  - bind to loopback and expose via Tailscale Serve (service never listens on LAN)

Both approaches are valid; choose per service based on operational needs.

The ACL cannot see the LAN. Services that listen on every address - Nextcloud's Apache, Samba on
vm102 and sshd on the hypervisor - would stay reachable from the home network and, over IPv6, from
any address in its prefix. The `lan_guard` role enforces the LAN side on each node
instead: an nftables table on the LAN interface drops every new inbound connection except replies,
ICMP, DHCP, Tailscale's UDP port and a short named list (SMB to vm102 from its two mounting nodes,
break-glass SSH and netconsole to the hypervisor). See the `lan_guard` role in
[ansible.md](ansible.md#roles).

Verified 2026-09-26: the router admits nothing inbound from the internet (no port shares, no
exposed host, no MyFRITZ! shares).

## Policy Tests

The tailnet policy file is HuJSON and accepts a `tests` block. Each entry names a source
identity and lists destinations that must be reachable and destinations that must not be;
when an assertion fails, Tailscale rejects the edited policy on save and does not apply it.

The block below has one entry per source role, per tier1 host and for the external user.

Deny assertions carry the weight here. An allow that breaks announces itself the next time somebody
uses the service; a deny that breaks is silent. Where a rule's source is a host alias, the test names
the host and not the tag, because a test from `tag:tier1` would say nothing about which of the
three tier1 nodes it describes.

```json
"tests": [
    {"src": "tag:admin",
     "accept": ["tag:tier0:22", "tag:tier0:8006", "tag:storage:445", "tag:control:22", "tag:monitoring:9443", "nextcloud:443"],
     "deny":   ["tag:database:5432", "tag:tier1:22", "tag:tier0:3128", "tag:admin:22", "gpu-vm:11434", "gpu-vm:8080", "bazzite:8080"]},
    {"src": "tag:control",
     "accept": ["tag:tier0:22", "tag:tier1:22", "tag:database:22", "tag:control:22", "tag:monitoring:9443"],
     "deny":   ["tag:admin:22", "tag:storage:445", "tag:tier0:8006", "tag:database:5432"]},
    {"src": "tag:monitoring",
     "accept": ["tag:tier0:9100", "tag:control:9100", "tag:database:9187", "nextcloud:443", "gpu-vm:8096", "gpu-vm:8080"],
     "deny":   ["tag:database:5432", "tag:storage:445", "tag:tier0:22", "tag:admin:9100", "bazzite:8080"]},
    {"src": "tag:tier0",
     "accept": ["tag:storage:445"],
     "deny":   ["tag:tier1:22", "tag:database:5432", "tag:monitoring:443"]},
    {"src": "paperless",
     "accept": ["tag:database:5432", "tag:monitoring:19532"],
     "deny":   ["nextcloud:443", "tag:storage:445", "tag:monitoring:22"]},
    {"src": "nextcloud",
     "accept": ["tag:storage:445"],
     "deny":   ["tag:database:5432", "paperless:443", "tag:monitoring:19532"]},
    {"src": "calibreweb",
     "deny":   ["nextcloud:443", "tag:database:5432", "tag:storage:445"]},
    {"src": "tag:ai-stack",
     "accept": ["tag:database:5432", "bazzite:8080", "gpu-vm:8080"],
     "deny":   ["tag:storage:445", "nextcloud:443", "bazzite:22", "bazzite:11434", "gpu-vm:11434"]},
    {"src": "tag:tier2",
     "deny":   ["tag:storage:445", "tag:database:5432", "tag:tier0:22"]},
    {"src": "tag:database",
     "accept": ["tag:monitoring:19532"],
     "deny":   ["tag:storage:445", "tag:monitoring:22", "tag:tier1:443"]},
    {"src": "tag:storage",
     "deny":   ["tag:tier0:22", "tag:database:5432"]},
    {"src": "tag:admin-mobile",
     "accept": ["tag:tier0:8006", "openwebui:443", "gpu-vm:8096", "paperless:443"],
     "deny":   ["tag:tier0:22", "tag:control:22", "tag:monitoring:443", "tag:storage:445"]},
    {"src": "tag:client",
     "accept": ["nextcloud:443", "paperless:443", "gpu-vm:8096", "gpu-vm:13378"],
     "deny":   ["openwebui:443", "tag:monitoring:443", "tag:tier0:8006", "tag:storage:445"]},
    {"src": "client-notebook",
     "accept": ["calibreweb:443"]},
    {"src": "tag:reader",
     "accept": ["calibreweb:443", "gpu-vm:13378"],
     "deny":   ["gpu-vm:8096", "nextcloud:443", "paperless:443"]},
    {"src": "tag:untrusted",
     "accept": ["gpu-vm:8096"],
     "deny":   ["gpu-vm:13378", "nextcloud:443", "calibreweb:443"]},
    {"src": "tag:isolated",
     "deny":   ["gpu-vm:8096", "tag:storage:445", "nextcloud:443"]},
    {"src": "tag:media-player",
     "accept": ["gpu-vm:8096"],
     "deny":   ["gpu-vm:13378", "gpu-vm:22", "tag:storage:445", "nextcloud:443", "tag:monitoring:443"]},
    {"src": "<external-user-email>",
     "accept": ["gpu-vm:8096", "gpu-vm:13378", "nextcloud:443"],
     "deny":   ["paperless:443", "calibreweb:443", "tag:storage:445", "gpu-vm:22"]}
]
```

The tests check the policy, not the fleet. The fleet is checked by TCP probes from the source nodes.

Verified 2026-09-26: 70 TCP connections from the servers and the admin notebook, every allowed path
open and every denied one closed, every node reachable by Ansible and every Prometheus target up.

A service that binds the wrong address is still reachable by anything the
kernel lets through, which is why [`smb-bind-and-lan-access.md`](../decisions/smb-bind-and-lan-access.md)
had to answer port 445 one layer further down.

## Documentation Rule

Every service document under `docs/services/` must include an `## Access Model` section and reference this document.
