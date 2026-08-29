#!/usr/bin/env bash
# Deploy the Mytheus modular monolith to the VPS. Idempotent: safe to re-run.
#
# This is the manual fallback path. Dokploy is the normal way to deploy (it runs the same
# compose file under the same project name, `mytheus`, so both paths drive one stack and one
# set of volumes). Keep this script working: it is what you reach for when Dokploy itself is
# the thing that is broken.
#
# Only THIS repo needs to be cloned; the backend arrives as a published image from GHCR, so
# the sibling mytheus-backend checkout the old version required is no longer involved.
# Requires env/prod.env (copied from env/prod.env.example and filled). Run from this dir:
#   ./deploy.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

ENV_FILE="../env/prod.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE is missing. Copy ../env/prod.env.example -> ../env/prod.env and fill it." >&2
  exit 1
fi

# Load POSTGRES_PASSWORD / PUBLIC_HOSTNAME etc. for compose variable interpolation.
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

echo "==> Pulling latest code"
git -C .. pull --ff-only || true

# --pull always, not --build. The backend image is built and published by mytheus-backend's
# CI; building it here would produce an image that matches no commit anyone can identify and
# would silently diverge from whatever Dokploy deploys.
echo "==> Pulling images + starting the stack"
docker compose -f compose.prod.yml up -d --pull always

# Hard gate, not a best-effort wait. The previous version looped 30 times on `web` and then
# fell through to "Done." whatever the outcome, so a container that never became healthy still
# produced a deploy that reported success. `set -e` cannot catch that: the loop itself exits 0.
wait_healthy() {
  local container="$1" status
  echo "==> Waiting for $container to become healthy"
  for _ in $(seq 1 30); do
    status="$(docker inspect --format '{{ .State.Health.Status }}' "$container" 2>/dev/null || echo missing)"
    echo "   $container: $status"
    [[ "$status" == "healthy" ]] && return 0
    sleep 5
  done
  echo "ERROR: $container did not become healthy within 150s." >&2
  docker logs --tail 50 "$container" 2>&1 | sed 's/^/   | /' >&2 || true
  return 1
}

# `meeting-service` is gated for the reason spelled out beside its healthcheck in
# compose.prod.yml: nothing anywhere else in the pipeline notices when it fails to come up.
wait_healthy mytheus-web-1
wait_healthy mytheus-meeting-service-1

# The event backbone is VERIFIED here, not created here.
#
# Creating it would mean a second copy of the topic list living in this repo, and the canonical
# one is `mytheus-events/scripts/create_topics.sh` (itself derived from
# `_canon/03-event-taxonomy.md`). This repo already has one vendored script that has drifted
# from its origin, so a second copy of 42 partition counts and retention settings is a defect
# waiting to happen: the drift would be silent and would land as wrong retention on production
# topics.
#
# Verifying instead gets the property that actually matters. It does not care HOW the topics
# were created, only that a deploy cannot report success while the backbone is missing. Before
# this, a fresh stack came up with zero topics and every producer either auto-created a
# 1-partition topic with default retention or failed at runtime, and `deploy.sh` said "Done."
#
# Counts, not names, for the same one-definition reason: 21 topics plus their 21 paired .dlq is
# 42, and one `{topic}-value` subject each is 21. Redpanda's own internal topics are excluded.
verify_event_backbone() {
  local topics subjects
  echo "==> Verifying the event backbone"

  topics="$(docker compose -f compose.prod.yml exec -T redpanda     rpk topic list 2>/dev/null | tail -n +2 | grep -cvE '^(_schemas|__consumer_offsets|_redpanda)' || true)"
  subjects="$(docker compose -f compose.prod.yml exec -T redpanda     curl -sf http://localhost:8081/subjects 2>/dev/null | grep -o '"' | wc -l || true)"
  subjects=$(( subjects / 2 ))

  echo "   topics: ${topics}/42   subjects: ${subjects}/21"

  if [[ "${topics:-0}" -lt 42 || "${subjects:-0}" -lt 21 ]]; then
    cat >&2 <<'UNPROVISIONED'
ERROR: the Redpanda topics and/or Avro subjects are not provisioned.

Producers would auto-create single-partition topics with default retention, which silently
loses the canonical partition counts and retention from _canon/03-event-taxonomy.md, or fail
outright where auto-creation is disabled. Refusing to report a successful deploy.

To provision, from a mytheus-events checkout with rpk and a Schema Registry reachable:

    BROKERS=<broker>:9092 bash scripts/create_topics.sh
    make register SR_URL=http://<host>:8081

Both are idempotent and safe to re-run.
UNPROVISIONED
    return 1
  fi
}

verify_event_backbone

echo "==> Current state"
docker compose -f compose.prod.yml ps
echo "Done. /healthz is served on https://${PUBLIC_HOSTNAME:-api.mytheus.cloud}/healthz"
