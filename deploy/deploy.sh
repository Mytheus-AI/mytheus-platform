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

echo "==> Current state"
docker compose -f compose.prod.yml ps
echo "Done. /healthz is served on https://${PUBLIC_HOSTNAME:-api.mytheus.cloud}/healthz"
