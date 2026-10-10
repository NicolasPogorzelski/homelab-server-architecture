# Tailscale ACL & Tagging Model (Policy-as-Code)

## Purpose

This platform uses Tailscale as the only remote-access path and as the identity layer for service-to-service communication.

Principles:

- LAN is not trusted
- No public ingress / no port-forwarding
- Access is identity-based and explicitly allowed
- Every grant names a port and, where a tag holds more than one service, a host
- Policy is managed as code (Tailscale ACL JSON), not ad-hoc per service

Source of truth: The active policy is the Tailscale ACL JSON in the Tailscale admin console.
This document mirrors it, sanitized: addresses are placeholders, and people appear by role, never
by name, device name or e-mail address.

The model was rebuilt on 2026-09-26 from a device-by-device review and from the flows measured on
the fleet that day. Every rule below answers to one of two sources: a connection observed on a node,
or a need the owner of a device stated. Anything else is closed.

---

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
| `tag:admin` | Operator workstations | admin notebook, admin desktop |
| `tag:admin-mobile` | Operator phone | one device |
| `tag:client` | End-user devices | a phone and a notebook |
| `tag:reader` | E-book reader | one device |
| `tag:untrusted` | A TV outside the home network, administered by nobody here | one device |
| `tag:media-player` | Streaming box at the TV: Jellyfin only | a streaming box |
| `tag:isolated` | No access at all: Mullvad-only devices and quarantine | none since 2026-10-01 |

**Exception:** Calibre-Web (lxc220) is tagged `tag:tier1`, not `tag:tier2`, despite being an
application service by the table above. Confirmed intentional (2026-07-08). Since the rebuild the
tag decides less than it did: every grant to a tier1 service names the host, so the three tier1
services are reachable independently of each other.

**Why lxc250 has its own tag.** Until 2026-09-26 the control node shared `tag:admin` with the
operator's devices, and `tag:admin:*` connected all of them on every port. The node that holds the
vault password, the Ansible key and root on the hypervisor was reachable on every port from a phone,
and could itself reach every port on the workstations. A human endpoint and an automation server are
two identities with two jobs; each now gets only its own.

---

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

---

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

---

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

lxc200 also scrapes its own native exporter on its Tailscale address, port 9101. That works without
a rule; measured 2026-09-26, both before and after the rebuild.

### Rule 2 - Journal upload (exercise)

The two nodes that opt into central log collection may reach the receiver on lxc200, and nothing
else there ([exercise decision](../decisions/exercise-scope-before-terraform.md)). The rule names
the Paperless host rather than `tag:tier1`, so Nextcloud and Calibre-Web cannot send.

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

Measured 2026-09-26: the host mounts eight shares from vm102, two of them over the tailnet and six
over the LAN, where the `smb_guard` table on vm102 admits the host and vm100 only
([samba.md](samba.md)). Nothing else the host does crosses the tailnet; guests are managed through
`pct` and `qm` on the host itself.

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

Port 11434 is closed on both hosts, and the tests below assert it: vm100's native Ollama was removed
on 2026-10-01, and nothing on the desktop listens there.

### Rule 7 - Admin workstations

Derived from the workstation's own configuration and the documentation rather than from "admin
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

### Rule 8 - Operator phone

The phone held `tag:admin` so that the host could be shut down from it. It now reaches the Proxmox
interface and the services its owner uses, and nothing else. The Proxmox side is meant to match: a
dedicated user whose role holds only `Sys.PowerMgmt`, with a second factor, so a stolen phone can
switch the host off and do nothing more. Until that user exists the login is still root's.

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

`openwebui:443` serves a mobile client for Open WebUI. Ollama's request log on vm100 over the
preceding 30 days held requests from lxc230 only, none from the phone, which is how the client's
path was established.

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
expiry is disabled for this device on purpose, because nobody on site could re-authenticate it; the
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

One external user reaches Jellyfin, Audiobookshelf and Nextcloud Talk. Until 2026-09-26 that user's
devices were members of this tailnet; now vm100 and lxc210 are shared into the user's own tailnet
instead. Tailscale's sharing documentation: "Sharing gives the recipient access to only the shared
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

The rule names the user's account rather than `autogroup:shared`, so a later share with somebody else
does not inherit these rights. A grant to an account covers all of its devices; per-device limits
would require keeping those devices in this tailnet, which is the arrangement this replaced.

### Rule 14 - Media player: the streaming box at the TV

The streaming box gets Jellyfin over the tailnet and nothing else. Until 2026-10-01 it carried
`tag:isolated` and reached Jellyfin over the LAN instead: in the 90 days to that date it opened 145
Jellyfin sessions from its LAN address and none from the tailnet, read from Jellyfin's activity log
and identified by its NVIDIA MAC prefix. Its own tag rather than a grant under `tag:isolated`,
because that tag promises no access at all. The Mullvad attribute stays, since it is bound to the
device's address, not to the tag.

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
The rebuild of 2026-09-26 left this flow out, and its test asserted the opposite; with the LAN path
closed by `smb_guard`, both mounts had failed since at least 2026-09-29. The grant is the one
service, not `tag:tier1`, and the mounts address vm102 by its full MagicDNS name, because the short
name `storage` also resolves on the LAN.

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

---

## Node Attributes

### Mullvad Exit Nodes

Five devices may use Tailscale's Mullvad exit nodes: both admin workstations, the operator phone,
an end-user phone and a streaming box.

```json
"nodeAttrs": [
    {"target": ["<tailscale-ip-admin-notebook>"],   "attr": ["mullvad"]},
    {"target": ["<tailscale-ip-admin-desktop>"],    "attr": ["mullvad"]},
    {"target": ["<tailscale-ip-operator-phone>"],   "attr": ["mullvad"]},
    {"target": ["<tailscale-ip-client-phone>"],     "attr": ["mullvad"]},
    {"target": ["<tailscale-ip-streaming-box>"],    "attr": ["mullvad"]}
]
```

Two things about this block were measured rather than read. The admin desktop had a Mullvad exit
node active on 2026-09-26 with no `autogroup:internet` grant in the policy, so the attribute alone
is enough for Mullvad, although Tailscale's own exit nodes need that grant. And the targets are
addresses, which Tailscale's policy reference does not list as a `nodeAttrs` selector (it names tags,
users, groups and `*`); the form was kept because it is the one that demonstrably works. Three
targets named addresses no device held any more and were removed in the rebuild - a new device
receiving one of them would have inherited the attribute.

---

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

---

## Administrative Access Model

Administrative access is separated from service-to-service communication.

- People's devices are tagged by role and reach services by host and port
- The control node is a separate identity from the operator's devices
- Service-to-service communication is controlled via tags, and via host aliases where a tag holds
  several services
- Break-glass access is documented and intentionally minimal

Note: the operator's workstations are intentionally absent from `docs/nodes/`. They are documented
through their tag and through the hardening notes in the [remediation plan](remediation-plan.md).

---

## Service Onboarding Checklist (Network)

For every new service that must be reachable remotely or must reach other services:

1. Decide the node tag(s) for this service, and whether a host alias is needed because the tag
   already holds another service
2. Update the Tailscale ACL JSON (allow rules)
3. Add a `tests` entry for the new path and for one path that must stay closed
4. Verify connectivity with a TCP probe from the source node, both directions of the claim
5. Ensure the service itself binds only to Tailscale (or loopback + Tailscale proxy)
6. Document the access model in the service doc

---

## Binding Rules (Zero Trust)

Default rules:

- Services must not bind to LAN interfaces unless explicitly justified
- Prefer:
  - bind to Tailscale IP (service listens directly on tailnet), or
  - bind to loopback and expose via Tailscale Serve (service never listens on LAN)

Both approaches are valid; choose per service based on operational needs.

The ACL cannot see the LAN. Services that listen on every address - Nextcloud's Apache and sshd on
most nodes - would stay reachable from the home network and, over IPv6, from any address in its
prefix. Since 2026-10-01 the `lan_guard` role enforces the LAN side on each node instead: an
nftables table on the LAN interface drops every new inbound connection except replies, ICMP, DHCP,
Tailscale's UDP port and a short named list (SMB to vm102 from its two mounting nodes, break-glass
SSH and netconsole to the hypervisor). See [ansible.md](ansible.md) and the rollout state in the
[remediation plan](remediation-plan.md#added-on-2026-10-01). The router admits nothing inbound from
the internet (measured on 2026-09-26: no port shares, no exposed host, no MyFRITZ! shares).

---

## Policy Tests

The tailnet policy file is HuJSON and accepts a `tests` block. Each entry names a source
identity and lists destinations that must be reachable and destinations that must not be;
when an assertion fails, Tailscale rejects the edited policy on save rather than applying it.

Deployed on 2026-09-26 with the rebuilt policy: eighteen entries, one for each role and for the
tier1 hosts individually. Until then the block was a proposal in this document, and the model had
been verified by hand once, during the 2026-08-17 audit.

Deny assertions carry the weight here. An allow that breaks announces itself the next time somebody
uses the service; a deny that breaks is silent. Where a rule's source is a host alias, the test names
the host rather than the tag, because a test from `tag:tier1` would say nothing about which of the
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

The tests check the policy, not the fleet. After the policy was saved and the devices re-tagged,
the fleet was probed as well: 70 TCP connections from the ten servers and the admin notebook, every
allowed path open and every denied one closed, all ten nodes reachable by Ansible and all nineteen
Prometheus targets up. A service that binds the wrong address is still reachable by anything the
kernel lets through, which is why [`smb-bind-and-lan-access.md`](../decisions/smb-bind-and-lan-access.md)
had to answer port 445 one layer further down.

## Documentation Rule

Every `docs/services/*.md` file must include an "Access Model (Zero Trust)" section and reference this document.

---

## Changelog

| Date | Change | Reason |
|---|---|---|
| 2026-10-10 | Rule 15 grants `nextcloud` -> `tag:storage:445`, and its test moves from deny to accept. Written in the repository; the console policy is applied by the operator. | Nextcloud's ingest mounts to Paperless had no path since the 2026-09-26 rebuild: the flow was not in the measured set, and `smb_guard` closes the LAN route. |
| 2026-10-01 | New `tag:media-player` with Rule 14 (`gpu-vm:8096` only) and a test; the streaming box moves to it from `tag:isolated`. Verified on vm100's packet filter: a new rule for 8096 with the device's two addresses | The box streamed over the LAN, the path that closes once vm100 stops publishing on it ([remediation plan](remediation-plan.md#added-on-2026-10-01)) |
| 2026-10-01 | Policy applied in the console: Rule 6 grants `bazzite:8080` and `gpu-vm:8080`, monitoring `gpu-vm:8080`; `gpu-vm:11434` removed with vm100's Ollama and asserted as denied. Verified on vm100's packet filter and by probes from lxc230, lxc200 and the admin notebook: allowed paths 200, denied paths time out | The 2026-09-29 change had reached the documentation only ([llm-inference.md](../services/llm-inference.md#rollout-state)) |
| 2026-09-29 | Inference moves to `llama-server` on 8080: Rule 6 grants `bazzite:8080` and `gpu-vm:8080` and drops `bazzite:11434`; `gpu-vm:11434` stays until vm100's Ollama is removed. Monitoring may probe `gpu-vm:8080`. Tests follow. Correction 2026-10-01: documentation only - the console policy was not changed that day, and vm100's packet filter carried no rule for 8080 until 2026-10-01 | [llm-inference.md](../services/llm-inference.md) |
| 2026-09-26 | Policy rebuilt. New tags `tag:control`, `tag:admin-mobile`, `tag:reader`, `tag:isolated`; `tag:client` narrowed to named services; `tag:gaming` and `tag:maintenance` retired. Grants by host and port; no `*` grant left; tier1 lateral access, tier0 workload access and unused SMB grants removed; journal upload added; an external user moved to machine sharing; three stale Mullvad targets dropped; eighteen tests deployed | Device-by-device review against measured flows; see the rules above |
| 2026-09-01 | Documentation only, no policy change: Vaultwarden removed from the tier1 service lists in Rule 1c and Rule 6. The `tag:tier1` definition stays, and so does the node's tag assignment in the Tailscale console, until the container is removed in phase 2 | Service decommissioned and the guest stopped ([decision](../decisions/vaultwarden-decommission.md)) |
| 2026-07-14 | Documentation only, no policy change: `tag:untrusted` re-described from "Guest / restricted devices" to the enumerated set it actually is (TVs). Rule 7 now states that the tier is admin-assigned per device and is not a guest-invite mechanism | The old wording described a broader and more open population than the tag has ever held, and read as if any invited device could join. The ACL itself is unchanged - `tagOwners: autogroup:admin` already made self-assignment impossible |
| (predates changelog) | LXC210 Nextcloud onboarded: `tag:tier1`, host alias added, Apache-managed TLS on :443 (not Tailscale Serve) | Nextcloud initial deployment; predates changelog start 2026-03-04 |
| 2026-03-04 | Added `tag:admin:*` to admin dst | Enable admin-to-admin communication (required after adding LXC250 devops) |
| 2026-03-04 | Changed tier1/tier2 storage port from 2049 (NFS) to 445 (SMB) | NFS was replaced by SMB; port rule was a leftover |
| 2026-03-09 | Added `tag:monitoring` to tier model, tag ownership, admin dst, and access matrix | Monitoring tag was missing from documentation |
| 2026-03-09 | Added Rule 1b (monitoring outbound scrape access on port 9100) | Container restart revealed missing outbound ACL (DD#11) |
| 2026-03-20 | Added `tag:database` to tier model, tag ownership, admin dst, monitoring scrape, and access matrix | PostgreSQL platform service (lxc260) uses dedicated platform tag (DD#12) |
| 2026-03-24 | Added `tag:ai-stack` to tier model, tag ownership, access matrix; added Rule 5 (ai-stack -> database:5432) | First database consumer (OpenWebUI CT230) onboarding |
| 2026-03-25 | Added `tag:ai-stack:*` to admin/tier0 dst; merged monitoring scrape into single rule with all tags; added storage:445 to ai-stack rule; added ai-stack:443 to client rule | OpenWebUI (CT230) ACL deployment and E2E verification |
| 2026-04-02 | Extended Rule 5 (ai-stack dst): added tag:admin:11434 and tag:tier2:11434 for Ollama inference backends | OpenWebUI requires direct Ollama access (admin workstation + VM100) |
| 2026-04-07 | Extended Rule 3 (tier1 dst): added tag:database:5432 | Paperless-ngx (CT211, tag:tier1) requires PostgreSQL access to lxc260 |
| 2026-04-10 | CT211 Paperless-ngx fully onboarded: tag:tier1, TS Serve https=443->8000, paperless_db@lxc260, E2E verified | Paperless-ngx operational and documented |
| 2026-04-22 | Extended Rule 1b (monitoring outbound): added `tag:monitoring:9100` (self-scrape), `tag:admin:9100`, `tag:database:9187` (postgres_exporter) | node_exporter fleet deployment + postgres_exporter on lxc260 |
| 2026-06-08 | Added Rule 1c (monitoring outbound service-probe): `tag:tier2:8096`, `tag:tier2:13378`, `tag:tier1:443`, `tag:ai-stack:443` | blackbox_exporter service-level probes (KE-8 remediation) require reaching service ports, not just node_exporter |
