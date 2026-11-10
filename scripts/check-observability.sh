#!/usr/bin/env bash
# Validate observability/: Grafana dashboards (scripts/check_dashboards.py, stdlib python) and the
# Prometheus config, alert rules and rule unit tests (promtool, from the same prom/prometheus image
# compose.prod.yml runs, so the checks match production). Exits non-zero on the first failure.
#
#   scripts/check-observability.sh
#
# prometheus.yml names its rule file by its in-container path (/etc/prometheus/alerts.yml), so
# promtool runs with observability/prometheus mounted there.
set -euo pipefail

cd "$(dirname "$0")/.."
PROM_IMAGE="prom/prometheus:v2.55.1" # keep in step with deploy/compose.prod.yml

python3 scripts/check_dashboards.py

promtool() {
  docker run --rm --entrypoint promtool \
    -v "$PWD/observability/prometheus:/etc/prometheus:ro" "$PROM_IMAGE" "$@"
}

promtool check config /etc/prometheus/prometheus.yml
for t in observability/prometheus/tests/*.yml; do
  promtool test rules "/etc/prometheus/tests/$(basename "$t")"
done
echo "observability OK"
