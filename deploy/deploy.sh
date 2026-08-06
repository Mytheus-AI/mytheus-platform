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

echo "==> Waiting for the web healthcheck"
for i in $(seq 1 30); do
  status="$(docker inspect --format '{{ .State.Health.Status }}' mytheus-web-1 2>/dev/null || echo starting)"
  echo "   web health: $status"
  [[ "$status" == "healthy" ]] && break
  sleep 5
done

echo "==> Current state"
docker compose -f compose.prod.yml ps
echo "Done. /healthz is served on https://${PUBLIC_HOSTNAME:-api.mytheus.cloud}/healthz"
