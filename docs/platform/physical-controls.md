# Physical and Environmental Controls

Everything else in this repository describes controls that run. This one describes the layer
underneath them, which runs on nothing and had never been written down.

It stopped being an abstract gap on 2026-08-15. The leading hypothesis for
[KE-14](known-errors.md#ke-14) - the intermittent I/O errors on the disk carrying every guest root
filesystem - is a sagging 12 V rail. That is an open incident whose suspected cause is exactly the
control nobody had recorded. A verification that keeps being intended and never scheduled is the
shape this document exists to break: written down, the check becomes a step with a precondition
rather than a recurring good idea.

Scope is the ISO/IEC 27001 Annex A.7 family as it applies to a single machine in a private
residence. The assessment is deliberately unflattering where it should be; see
[`security-controls.md`](security-controls.md) for how the rest of the estate is rated and for
what "Enforced" means there.

## The environment in one paragraph

One tower-format server in a private flat, on ordinary household mains, on a consumer-grade
uninterruptible supply that has never been load-tested. No rack, no raised floor, no dedicated
circuit, no environmental sensing beyond the temperature the disks report themselves. Physical
access is limited to the occupants of the flat; no landlord, cleaner, or contractor has routine
unaccompanied access, and no third party has ever needed to touch the machine. The host powers
itself down every night on an RTC wake schedule, which is a power-consumption decision that turns
out to matter here twice - see below.

## Controls, honestly rated

| Annex A | Control | State | What actually holds it |
|---|---|---|---|
| A.7.1 | Physical security perimeter | Partial | The flat's own door. There is no second boundary between the front door and the machine |
| A.7.2 | Physical entry | Partial | Occupants only. No log, because there is nobody to log |
| A.7.3 | Securing offices and rooms | None | The server shares a room with ordinary living space |
| A.7.4 | Physical security monitoring | None | No camera, no door contact, no tamper evidence on the case |
| A.7.5 | Protecting against physical and environmental threats | Partial | Smoke detection in the flat. No water detection, no fire suppression near the machine |
| A.7.8 | Equipment siting and protection | Partial | Off the floor, clear airflow. Not in a locked enclosure |
| A.7.11 | Supporting utilities | **Weak, and it is load-bearing** | A consumer UPS of unrecorded age and capacity, never tested under load and never tested for runtime. [KE-14](known-errors.md#ke-14) suspects the power path already |
| A.7.12 | Cabling security | Partial | Internal cabling reseated once during the KE-13 diagnosis; nothing is documented about it |
| A.7.13 | Equipment maintenance | Partial | Reactive. Dust and thermals are checked when something else brings the case open |
| A.7.14 | Secure disposal or re-use | **Open with a deadline** | The KE-13 disk leaves the flat when it is replaced, carrying C1 data on 7680 sectors a software overwrite cannot be assumed to reach. Degauss or destroy; nothing else is honest |
| A.7.10 | Storage media | Partial | Disks are not encrypted at rest - see the paragraph below, which is the one entry here that is a decision rather than an omission |

## Encryption at rest: not implemented, and why that is a choice

No disk on this host is encrypted. That is a real gap against theft and against disposal, and it
is not an oversight.

Full-disk encryption on a machine that powers itself down every night and boots unattended needs
the key available without a human. The options are a key file on an unencrypted partition, which
protects against nothing an attacker with the machine cannot defeat, or a TPM-sealed key, which
this board does not offer, or typing a passphrase at every boot, which would end the nightly power
cycle and with it the reason the schedule exists.

So the threat this would close - somebody takes the machine - is instead accepted and stated. It
is worth being precise about what that costs: the C1 datasets in
[`data-classification.md`](data-classification.md) are readable by anyone holding the disks. That
includes the Nextcloud files, the Paperless documents and both database dump sets.

The half of this that is not accepted is disposal, A.7.14 above. A disk that leaves the flat leaves
with its contents, and that is why the KE-13 replacement carries a destruction step rather than a
wipe.

## `pve-firewall` is off, and that is also a choice

The Proxmox firewall is disabled on the host. Found by the 2026-08-20 audit and recorded here
because an undocumented deliberate choice reads exactly like an oversight at review time - which is
the same argument this repository makes about a mask left behind after its cause is gone.

The reasoning: inbound exposure is governed by the Tailscale ACL policy, which is enforced at the
overlay rather than at the host, and the one service that cannot bind correctly on the LAN is
fenced by the nftables table on vm102. Adding `pve-firewall` would put a second, differently
expressed policy in front of the same traffic, and two policies that must agree are how a rule gets
changed in one of them.

What that argument does not cover, and is the honest counter: the LAN is declared untrusted, and on
the hypervisor nothing enforces that declaration at the host boundary. Every wildcard bind found by
the audits - sshd on ten of eleven nodes, Apache on lxc210, Alertmanager's cluster port - is
reachable from the LAN precisely because no host filter exists. The ACL answers for the overlay and
nothing answers for the wire. That belongs in the sshd binding decision rather than here, and it is
the reason that decision is a fleet decision.

## What to do with this

Three of these are cheap and none is scheduled:

1. **Record the UPS.** Model, age, battery date, and one measured runtime test under real load. It
   is the control KE-14 already suspects, and "never tested" and "working" are indistinguishable
   until the mains go.
2. **Do the KE-14 power-path check.** The procedure is a runbook now:
   [`ke14-power-path-check.md`](../../runbooks/platform/ke14-power-path-check.md). It needs host
   downtime, which the nightly cycle already provides, and no purchase.
3. **Decide the disposal method before the disk arrives**, not after. A replacement disk creates
   time pressure that a decision made in advance does not feel.

## Related Documents

- [KE-14 - boot SSD I/O errors, power path unverified](known-errors.md#ke-14)
- [KE-13 - the auxiliary disk that will need disposing of](known-errors.md#ke-13)
- [Security Controls](security-controls.md)
- [Data Classification](data-classification.md)
- [Proxmox Host](proxmox-host.md)
- [Remediation Plan](remediation-plan.md)
