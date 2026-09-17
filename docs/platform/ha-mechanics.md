# How Proxmox HA Works, and Why It Stays Off Here

**Nothing was changed to write this document.** It is one of the four controls
taken on to be understood rather than because this platform needs them
([decision](../decisions/exercise-scope-before-terraform.md)), and it is the one
whose exercise had to stop at reading. Arming high availability on a single node
means arming a mechanism whose job is to reset that node, with nothing standing
by to take the guests. Every command below is a read, and every output is this
host on 2026-09-17.

## The parts, and which of them are already running

Proxmox HA is four pieces that are usually described as one.

**corosync** carries cluster membership and decides who is quorate. It is the
only piece this host does not have:

```
# pvecm status
Error: Corosync config '/etc/pve/corosync.conf' does not exist - is this node part of a cluster?
rc=2
```

**pmxcfs**, the cluster filesystem mounted at `/etc/pve`, distributes
configuration and holds the HA state machine's files. On a node with no corosync
it runs in local mode and is trivially quorate with itself, which produces the
first thing worth noticing:

```
# ha-manager status
quorum OK
```

That line says nothing about a cluster. It says one node agrees with itself.
Read without the `pvecm` output above it, it is exactly the kind of green that
this repository keeps finding underneath a fault.

**The CRM**, one cluster resource manager, decides what should run where.
**The LRM**, one local resource manager per node, does it. Both run here and are
enabled out of the box:

```
# systemctl is-active pve-ha-lrm pve-ha-crm watchdog-mux
active active active
```

**watchdog-mux** multiplexes the hardware watchdog so several HA components can
depend on one device. It is `WantedBy=pve-ha-lrm.service pve-ha-crm.service`,
which is why it is running on a machine with no HA resources at all.

## The device that is already armed

```
# cat /sys/class/watchdog/watchdog0/identity
Software Watchdog
# cat /sys/class/watchdog/watchdog0/state
active
# cat /sys/class/watchdog/watchdog0/timeout
10
```

A ten-second timer is running against this hypervisor right now, held open and
fed by `watchdog-mux`. The kernel loads `softdog` at `nowayout=0`, so if that
process dies its descriptor closes and the timer stops with it - the watchdog is
lost, not the host. The same reading with `nowayout=1` would be the opposite, and
that single parameter is the difference between a safety device and a hazard.

## What is missing, and it is the only thing missing

```
# cat /etc/pve/nodes/<node>/lrm_status
{"timestamp":1789649984,"state":"wait_for_agent_lock","mode":"active","results":{}}
```

`wait_for_agent_lock` is the LRM idling. It has acquired no agent lock because
there are no HA resources to manage, so it never enters `active` work, never
registers a client with `watchdog-mux`, and nothing ever stops the feeding.

That is the whole of why this platform is safe with the stack running. Not
because the pieces are absent - all but one are present and started - but because
no resource exists to put the last piece in motion.

## The chain, if a resource did exist

1. The LRM acquires its agent lock and takes responsibility for a guest.
2. It registers with `watchdog-mux`, which now has a client whose health it
   tracks.
3. Every cycle, the LRM confirms it still holds the lock and is still quorate,
   and tells `watchdog-mux` so.
4. `watchdog-mux` feeds `/dev/watchdog` on the strength of that confirmation.
5. If the LRM loses quorum or its lock, or stops answering, the feeding stops.
6. Ten seconds later the kernel resets the machine.

Step 6 is fencing, and it is the correct behaviour: a node that cannot prove it
is healthy must not keep running guests another node may be about to start. In a
cluster that is a safety property. On one node it is a machine that reboots
itself and comes back to exactly the same situation.

## Why it stays off here, in one sentence per reason

- **There is nobody to fail over to.** Fencing frees a workload for another node
  to claim. With one node the workload goes down either way, and the reset adds
  the boot time of eleven guests to an outage that did not need it.
- **A transient becomes an outage.** Anything that stalls the LRM - a pmxcfs
  hiccup, storage that stops answering, the kernel oops this platform already has
  on file as [KE-21](known-errors.md#ke-21) - stops the feeding, and the machine
  resets rather than degrades.
- **A reboot loop is reachable.** A fault that reproduces after boot cycles the
  host indefinitely, and the exit is the power button, which is the outcome the
  watchdog was supposed to prevent.
- **The platform is documented as recovery-oriented and explicitly not highly
  available.** Turning on half a clustering feature to obtain a reboot timer
  inverts the design rather than extending it.

This is the same conclusion the panic-and-watchdog decision reached on
2026-09-11; what is new here is that the mechanism is written down rather than
referred to.

## What it looks like where it belongs

| Here | In a place with a cluster |
|---|---|
| One node, quorate with itself | Three or more, quorum a real majority, a tie-break vote for even counts |
| No shared storage; guest disks are local | Shared or replicated storage, so another node can start the same guest |
| Fencing resets the only machine | Fencing frees a workload another node claims within seconds |
| `softdog`, a kernel timer | A hardware watchdog on the board, or fencing through a management processor, which survives a kernel that is gone |
| No maintenance mode to think about | `ha-manager crm-command node-maintenance`, because patching a node must not look like a node that died |
| Failure is noticed by a person | Failure is noticed by the cluster, and the person reads about it afterwards |

## What this setup cannot exercise at all

Split brain. It needs two halves that can each believe they are the survivor, and
that requires a second node and a network that can partition between them. Every
interesting HA failure - fence races, a node resurrected with stale state, a
quorum device that votes for the wrong side - lives on the far side of that line.
Reading about them is not the same as having seen one, and this platform cannot
produce one.

## Where to look again

- The decision that keeps the watchdog unarmed:
  [Hypervisor Panic Policy and softdog](../decisions/hypervisor-panic-and-watchdog.md)
- The incident that raised the question:
  [KE-21](known-errors.md#ke-21)
- Why this document exists at all:
  [Controls Built to Be Learned](../decisions/exercise-scope-before-terraform.md)
