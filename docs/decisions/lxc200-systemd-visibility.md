# lxc200: the Node That Watches the Fleet and Not Itself

## Status

Decided 2026-09-11. Chosen option is a native `node_exporter` beside the container, not a
privileged container.

## Context

`SystemdUnitFailed` covers every node except lxc200, and the reason is structural rather than an
oversight. lxc200's `node_exporter` is a Docker container from the monitoring compose stack. It
sees the container's own process namespace, not the host's systemd, so `--collector.systemd` has
nothing to collect. `node-exporter.yml` therefore runs against `all:!lxc200`.

lxc250 was the second such node until 2026-08-20, for a different reason - nothing scraped it - and
that one is closed. lxc200 is now the only blind spot, and it is the monitoring node.

That last sentence is the whole weight of this decision. A failed unit on the node that runs
Prometheus, Grafana, Alertmanager and the blackbox exporter reaches no alert. The failure would be
invisible in the same way the host `node_exporter` outage was invisible: the component that would
report the fault is the component that is down.

## Options

**Privileged container with `/run/systemd` bind-mounted.** Gives the containerised exporter access
to the host's systemd. Rejected. It means either running the exporter container privileged or
bind-mounting a socket that carries the ability to start and stop units on the node - a large
authority grant to close a monitoring gap, on the node that holds the alerting stack. The
[data classification](../platform/data-classification.md) has this node one tier from the top for
good reason.

**Accept the gap and say so.** The current state. Rejected on the grounds above: it is not the
node to be blind on.

**A second, native `node_exporter` on lxc200 beside the container.** Chosen.

**Replace the container exporter with a native one.** The tidier end state, and the one to reach
eventually. Not chosen as the first step because lxc200's Prometheus scrapes `127.0.0.1:9100` today
and that target is wired into a config this repository renders; changing it is a change to the
monitoring stack's own configuration at the same time as a change to what it measures.

## Decision

Install `node_exporter` on lxc200 as a systemd unit through the existing role, bound to the node's
Tailscale address on a port other than 9100, with `--collector.systemd` enabled and the container's
exporter left alone on loopback. One new scrape target, one new job in the rendered Prometheus
config.

Two exporters on one node is not elegant and the inelegance is the point of writing this down: it
is a deliberate duplication with one job each. The container reports the node's resources as every
other node reports them; the native unit reports systemd unit state, which the container
structurally cannot. When the container exporter is eventually retired, this decision is what says
which of the two was load-bearing.

The port is not 9100 because that is taken by the container. Any free port above 9100 will do; what
matters is that it is recorded in the Prometheus target table in
[`monitoring.md`](../platform/monitoring.md) rather than remembered.

## Consequences

- `SystemdUnitFailed` covers eleven of eleven nodes for the first time.
- One more thing on lxc200 that can fail. It is a small Go binary with a readiness gate, which is
  the same thing running on nine other nodes.
- `node-exporter.yml` loses its `all:!lxc200` exclusion, which has been carrying an explanation in
  a comment since it was written.

## Verification

```bash
# On lxc200, after the role:
ss -tlnp | grep node_exporter          # two listeners: loopback 9100, Tailscale <new port>
curl -s <tailscale-ip-lxc200>:<port>/metrics | grep -c node_systemd_unit_state
```

The second command returning a count in the hundreds is the proof. On lxc250 the equivalent
adoption produced 850 `node_systemd_unit_state` time series, and that number is what made
`SystemdUnitFailed` real there rather than nominal.

In Prometheus, the target must be `up` and the rule must evaluate against it - the
`FleetRulesMismatch` check compares loaded rules against this repository, which does not catch a
rule that is loaded but has no series to read. Confirm by name:

```promql
count by (instance) (node_systemd_unit_state)
```

Eleven instances, not ten.

## Related Documents

- [Monitoring](../platform/monitoring.md)
- [LXC200 node document](../nodes/lxc200.md)
- [Remediation plan](../platform/remediation-plan.md)
- [KE-15 - the month of failed units nobody could see](../platform/known-errors.md#ke-15)
