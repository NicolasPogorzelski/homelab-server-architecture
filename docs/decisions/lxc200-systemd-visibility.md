# lxc200 Runs a Native node_exporter for systemd Unit State

## Status
Implemented 2026-09-15. Decided 2026-09-11. Supersedes / superseded by: -.

## Context
lxc200's `node_exporter` is a container in the monitoring compose stack. It sees the container's
process namespace, not the node's systemd, so `--collector.systemd` has nothing to collect and
`SystemdUnitFailed` could not cover lxc200. Every other node reports unit state.

lxc200 runs Prometheus, Grafana, Alertmanager and the blackbox exporter. A failed unit there reached
no alert: the component that would report the fault was the one that was blind
([KE-15](../platform/known-errors.md#ke-15) shows what a month of unseen failed units costs).

## Options
- **Privileged exporter container with `/run/systemd` bind-mounted.** Lost: grants the ability to
  start and stop units on the node holding the alerting stack, to close a monitoring gap.
- **Accept the gap.** Lost: the monitoring node is the one node not to be blind on.
- **Replace the container exporter with a native one.** Lost as a first step: Prometheus scrapes
  `127.0.0.1:9100` today, so it changes the monitoring configuration and what it measures at once.
  It remains the tidier end state.
- **A second, native `node_exporter` beside the container.** Chosen.

## Decision
`node_exporter` is installed on lxc200 as a systemd unit through the `node_exporter` role, bound to
the node's Tailscale address on port 9101 (`node_exporter_port` in `host_vars/lxc200.yml`, since the
container holds 9100), with `--collector.systemd` enabled. The container exporter stays on loopback
and reports resources like every other node; the native unit reports systemd unit state.

The rendered Prometheus configuration names the native target explicitly as
`node-lxc200-monitoring-systemd` (`ansible/roles/prometheus_config/templates/prometheus.yml.j2`).
The per-node loop would have emitted a second `node-lxc200-monitoring` job, and Prometheus rejects a
whole configuration that contains two jobs of one name.

## Consequences
- `SystemdUnitFailed` covers all ten nodes.
- Two exporters on one node, each with one job. When the container exporter is retired, the native
  unit is the one that carries systemd state.
- One more unit on lxc200 that can fail; the same binary and readiness gate run on every other node.
- The port is recorded in the target table in [`monitoring.md`](../platform/monitoring.md).

## Verification
```bash
# On lxc200:
ss -tlnp | grep node_exporter          # two listeners: loopback 9100, Tailscale 9101
curl -s <tailscale-ip-lxc200>:9101/metrics | grep -c node_systemd_unit_state
```

A count in the hundreds is the proof. In Prometheus the target must be `up` and the rule must have
series to read; `FleetRulesMismatch` compares loaded rules, not whether a rule has data:

```promql
count by (instance) (node_systemd_unit_state)
```

Expected: ten instances.

## Related Documents
- [Monitoring](../platform/monitoring.md)
- [LXC200 node document](../nodes/lxc200.md)
