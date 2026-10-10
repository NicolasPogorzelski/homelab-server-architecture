# Prometheus Rules

`alert.rules.yml` holds every alerting and recording rule Prometheus on lxc200 loads. The
`prometheus_config` role deploys it to `/opt/monitoring/prometheus/rules/` and gates the swap on
`promtool check rules`.

The catalogue of alerts, grouped as in the file, is the alerting table in
[`monitoring.md`](../../../../docs/platform/monitoring.md#alerting). `validate-repo.sh` Check 38 keeps
that table and this file in step, so it is the place to read rather than a list here.

## Tests

`tests/` holds `promtool` unit tests for rules whose behaviour is not obvious from the expression.
They are not deployed: the role copies `alert.rules.yml` alone, and Prometheus loads
`rules/*.yml` without descending into subdirectories.

```bash
cd docker/monitoring/prometheus/rules/tests
podman run --rm -v "$PWD/..:/r:ro,Z" -w /r/tests --entrypoint promtool \
  docker.io/prom/prometheus:v3.15.0 test rules smart.test.yml
```

Use the image tag the monitoring stack pins, so the test runs the PromQL engine that evaluates
the rules in production.
