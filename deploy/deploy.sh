#!/usr/bin/env bash
# Deploy the Mytheus modular monolith to the VPS. Idempotent: safe to re-run.
#
# Assumes both repos are cloned side by side on the box (see deploy/README.md):
#   ~/mytheus/mytheus-platform  (this repo)  and  ~/mytheus/mytheus-backend
# and that env/prod.env exists (copied from env/prod.env.example and filled). Run from this dir:
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
git -C ../../mytheus-backend pull --ff-only || true

echo "==> Building + starting the stack"
docker compose -f compose.prod.yml up -d --build

echo "==> Waiting for the web healthcheck"
for i in $(seq 1 30); do
  status="$(docker inspect --format '{{ .State.Health.Status }}' mytheus-web-1 2>/dev/null || echo starting)"
  echo "   web health: $status"
  [[ "$status" == "healthy" ]] && break
  sleep 5
done

echo "==> Current state"
docker compose -f compose.prod.yml ps
echo "Done. /healthz is served via Caddy on https://${PUBLIC_HOSTNAME:-srv1756037.hstgr.cloud}/healthz"
