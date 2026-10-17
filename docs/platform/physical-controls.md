# Physical and Environmental Controls

The ISO/IEC 27001 Annex A.7 family as it applies to one machine in a private residence: what holds
each control, and the two decisions that leave a control deliberately open. The status of each
control is owned by [`security-controls.md`](security-controls.md#physical-and-environmental-controls-a7).

## The environment

One tower-format server in a private flat, on household mains and a consumer-grade UPS that has
never been load-tested. No rack, no dedicated circuit, no environmental sensing beyond the
temperatures the disks report. Physical access is limited to the occupants; nobody else has routine
unaccompanied access. The host runs the hypervisor and its nine guests, powers down every night and
wakes on an RTC schedule (`homelab_schedule` defaults), which makes an unattended boot part of every
day.

## What holds each control

| Annex A | Control | What holds it |
|---|---|---|
| A.7.1 | Physical security perimeter | The flat's door; no second boundary between it and the machine |
| A.7.2 | Physical entry | Occupants only; no entry record |
| A.7.3 | Securing offices and rooms | Nothing: the server shares a room with ordinary living space |
| A.7.4 | Physical security monitoring | Nothing: no camera, door contact or tamper seal on the case |
| A.7.5 | Physical and environmental threats | Smoke detection in the flat; no water detection, no fire suppression near the machine |
| A.7.8 | Equipment siting and protection | Off the floor with clear airflow; not in a locked enclosure |
| A.7.10 | Storage media | No encryption at rest, by decision (below) |
| A.7.11 | Supporting utilities | A UPS of unrecorded age and capacity, never tested for runtime. [KE-14](known-errors.md#ke-14) suspects the power path |
| A.7.12 | Cabling security | Internal cabling reseated once during the KE-13 diagnosis; otherwise undocumented |
| A.7.13 | Equipment maintenance | SMART counters alerted on growth (`smart_metrics`); dust and thermals checked when the case is open for another reason |
| A.7.14 | Secure disposal or re-use | No procedure. The KE-13 disk leaves the flat when it is replaced, carrying C1 data on sectors a software overwrite cannot be assumed to reach |

## Encryption at rest is not implemented

No disk on this host is encrypted. Full-disk encryption on a machine that boots unattended every
morning needs the key without a human: a key file on an unencrypted partition protects against
nothing, the board offers no TPM to seal a key, and a passphrase at every boot ends the nightly
power cycle.

The accepted consequence: anyone holding the disks can read the C1 datasets in
[`data-classification.md`](data-classification.md), including the Nextcloud files, the Paperless
documents and both database dump sets. Disposal is not accepted on the same terms; a disk that
leaves the flat is degaussed or destroyed, not wiped.

## `pve-firewall` is off

The Proxmox firewall is disabled. Inbound exposure on the tailnet is governed by the Tailscale ACL
([`tailscale-acl.md`](tailscale-acl.md)). On the LAN, `lan_guard` (since 2026-10-01) drops every new
inbound connection on every node, the hypervisor included, except SMB to vm102 from vm100 and the
hypervisor, and break-glass SSH and netconsole to the hypervisor (`ansible/roles/lan_guard/`,
`ansible/inventory/group_vars/proxmox.yml`). A second, differently expressed policy in
`pve-firewall` would have to agree with `lan_guard` on the same traffic, and two policies that must
agree are how a rule changes in one of them only.

## Open items

Tracked in the [remediation plan](remediation-plan.md):

- Record the UPS (model, age, battery date) and measure one runtime under real load
  ([power path and UPS](remediation-plan.md#power-path-and-ups)).
- Run [`ke14-power-path-check.md`](../../runbooks/platform/ke14-power-path-check.md) if the KE-14
  errors follow the replacement boot SSD.
- Decide the disposal method for the KE-13 disk before the replacement arrives
  ([aux-disk replacement and disposal](remediation-plan.md#aux-disk-replacement-and-disposal)).

## Related documents

- [KE-14 - boot SSD I/O errors, power path unverified](known-errors.md#ke-14)
- [KE-13 - the auxiliary disk due for disposal](known-errors.md#ke-13)
- [Proxmox Host](proxmox-host.md)
