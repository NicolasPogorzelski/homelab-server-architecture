# Prometheus Rules

`alert.rules.yml` holds every alerting and recording rule Prometheus on lxc200 loads. The
`prometheus_config` role deploys it to `/opt/monitoring/prometheus/rules/` and swaps it in only
after `promtool check rules` passes. The alert catalogue is the alerting table in
[`monitoring.md`](../../../../docs/platform/monitoring.md#alerting); the repository validator keeps
that table in step with this file.

## Tests

`tests/` holds `promtool` unit tests for rules whose behaviour is not obvious from the expression.
They are not deployed: the role copies `alert.rules.yml` alone, and Prometheus does not load
subdirectories of `rules/`. CI does not run them; run them before changing a covered rule.

| File | Covers |
|---|---|
| `database.test.yml` | `DatabaseBackupMetricsMissing`: one alert per missing metric, two on one job |
| `host-config.test.yml` | `HostConfigBackupStale`: stale archive and absent metric |
| `jellyfin.test.yml` | `JellyfinCudaLost`: quick recovery stays quiet, ten minutes without CUDA fires |
| `listeners.test.yml` | `listeners` group: wildcard listener hold time, missing listener metrics |
| `rule-health.test.yml` | `PrometheusRuleEvaluationFailing` |
| `smart.test.yml` | `smart` group: kernel letters swapping across boots, real rise, fall, link CRC rise |

Run them with the Prometheus image the monitoring stack pins, so the tests use the PromQL engine
that evaluates the rules in production:

```bash
cd docker/monitoring/prometheus/rules/tests
image=$(awk '/image: prom\/prometheus:/ {print $2}' ../../../docker-compose.yml)
for t in *.test.yml; do
  podman run --rm -v "$PWD/..:/r:ro,Z" -w /r/tests --entrypoint promtool \
    "docker.io/$image" test rules "$t"
done
```

Keep input series intervals within the five-minute lookback. Wider spacing makes series vanish
between samples, and an alert with `for:` then never leaves `pending`.
