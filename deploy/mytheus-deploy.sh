#!/usr/bin/env bash
# ======================================================================================
# REVIEWED COPY of /usr/local/sbin/mytheus-deploy.sh  -  NOT THE LIVE FILE.
#
# >>> The VPS copy MUST be diffed against this file before it is adopted. <<<
#       ssh <vps> cat /usr/local/sbin/mytheus-deploy.sh | diff -u - deploy/mytheus-deploy.sh
#
# Why this exists (status-overview gap 26 / plan 3-4 gap 10b): the script that performs EVERY
# production deploy lived only on the VPS, in no repository, so it could not be reviewed,
# diffed or rolled back. This file is a RECONSTRUCTION, written without access to the VPS copy,
# from (a) how it is invoked and (b) what the docs say it does:
#   - mytheus-backend/.github/workflows/ci.yml (deploy job) and mytheus-platform/.github/
#     workflows/deploy.yml: `ssh root@$VPS_HOST` with NO command; the key's forced command in
#     authorized_keys runs this script. CI then curls https://api.mytheus.cloud/healthz.
#   - mytheus-docs/work-done-till-now/05-deployment-and-cicd.md section 2 and 8: fetches the
#     pinned revision; asserts every credential file exists AND the rendered compose config
#     carries a DATABASE_URL for all four backend roles BEFORE touching the running stack;
#     syncs deploy/caddy/mytheus.caddy into the Caddy conf.d mount, validating first and
#     restoring the previous fragment on failure; waits on container health.
#   - deploy/deploy.sh (the manual fallback) for the compose + wait_healthy + backbone check.
# Where the docs are silent, a value below is a GUESS and is marked `ASSUMED`. Differences
# from the live script are expected; the point of the diff is to find and reconcile them.
#
# Constraint: it is a forced command. It must take NO arguments or stdin and must never
# execute anything derived from SSH_ORIGINAL_COMMAND. Idempotent; safe to re-run.
# ======================================================================================
set -euo pipefail

# Forced-command hygiene: ignore whatever the client tried to run.
unset SSH_ORIGINAL_COMMAND

REPO_DIR="${MYTHEUS_REPO_DIR:-/srv/mytheus/mytheus-platform}"          # ASSUMED (README: /srv/mytheus/...)
ENV_DIR="${MYTHEUS_ENV_DIR:-/etc/dokploy/mytheus-secrets/env}"          # matches compose.prod.yml default
BRANCH="${MYTHEUS_DEPLOY_BRANCH:-main}"                                 # ASSUMED
CADDY_CONF_D="${MYTHEUS_CADDY_CONF_D:-/srv/mytheus/caddy/conf.d}"       # from 05-deployment doc
CADDY_CONTAINER="${MYTHEUS_CADDY_CONTAINER:-}"                          # UNKNOWN: name of atithivishram-prod's caddy
PROJECT=mytheus
COMPOSE=(docker compose -p "$PROJECT" -f "$REPO_DIR/deploy/compose.prod.yml")

log() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# Single deploy at a time (CI also serialises, but Dokploy / a human may not).
exec 9>/var/lock/mytheus-deploy.lock
flock -n 9 || die "another deploy is running"

# 1. Fetch the pinned revision. ff-only: a diverged checkout is a stop, not a merge.
log "Fetching $BRANCH"
git -C "$REPO_DIR" fetch origin "$BRANCH"
git -C "$REPO_DIR" merge --ff-only "origin/$BRANCH"

# 2. Credential assertions BEFORE touching the stack.
log "Checking credential files in $ENV_DIR"
required=(prod.env prod.db.app.env prod.db.relay.env prod.db.migrate.env prod.db.temporal.env prod.ui.env)
for f in "${required[@]}"; do
  [[ -s "$ENV_DIR/$f" ]] || die "missing or empty credential file: $ENV_DIR/$f"
done
[[ -s "$ENV_DIR/prod-bootstrap.sql" ]] || die "missing $ENV_DIR/prod-bootstrap.sql"

# The rendered config must actually carry DATABASE_URL for web, relay, workflow, migrate
# (the failure mode that cost a debugging session: env_file silently resolving to nothing).
cfg="$("${COMPOSE[@]}" config --format json)"
for svc in web relay workflow migrate; do
  grep -q . <<<"$(jq -r --arg s "$svc" '.services[$s].environment.DATABASE_URL // empty' <<<"$cfg")" \
    || die "rendered config has no DATABASE_URL for service '$svc'"
done

# Optional tiers: if a profile is enabled, its secrets and images must be ready, otherwise
# `up` half-starts. (NEW vs. the documented script; review before adopting.)
case ",${COMPOSE_PROFILES:-}," in *,intelligence,*)
  for f in prod.platform.env prod.qdrant.env prod.embedding.env prod.search.env prod.ingestion.env prod.db.ai.env prod.db.ai-relay.env; do
    [[ -s "$ENV_DIR/$f" ]] || die "intelligence profile on but missing $ENV_DIR/$f"
  done
  # Qdrant with no key configured is open to the whole docker network, and the two keys must differ.
  w="$(grep -E '^QDRANT__SERVICE__API_KEY=' "$ENV_DIR/prod.qdrant.env" | cut -d= -f2-)"
  r="$(grep -E '^QDRANT__SERVICE__READ_ONLY_API_KEY=' "$ENV_DIR/prod.qdrant.env" | cut -d= -f2-)"
  [[ -n "$w" && -n "$r" && "$w" != "$r" ]] || die "prod.qdrant.env needs two distinct, non-empty Qdrant keys"
  ;; esac

# 3. Caddy fragment: validate before reload, restore on failure. The fragment is spliced into
#    ANOTHER product's Caddyfile, so a syntax error would take their domains down too.
if [[ -n "$CADDY_CONTAINER" ]]; then
  log "Syncing Caddy fragment"
  mkdir -p "$CADDY_CONF_D"
  dest="$CADDY_CONF_D/mytheus.caddy"
  backup="$(mktemp)"
  [[ -f "$dest" ]] && cp -p "$dest" "$backup" || : > "$backup"
  cp "$REPO_DIR/deploy/caddy/mytheus.caddy" "$dest"
  if docker exec "$CADDY_CONTAINER" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile; then
    docker exec "$CADDY_CONTAINER" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
  else
    cp -p "$backup" "$dest"
    die "Caddy validation failed; previous fragment restored, nothing reloaded"
  fi
else
  log "MYTHEUS_CADDY_CONTAINER unset: skipping Caddy sync (set it to enable)"
fi

# 4. Bring the stack up. Images are PULLED (built by CI), never built here.
log "Pulling images + starting the stack"
"${COMPOSE[@]}" up -d --pull always

# 5. Hard health gate (same helper as deploy.sh).
wait_healthy() {
  local c="$1" st
  for _ in $(seq 1 30); do
    st="$(docker inspect --format '{{ .State.Health.Status }}' "$c" 2>/dev/null || echo missing)"
    [[ "$st" == healthy ]] && { echo "   $c: healthy"; return 0; }
    sleep 5
  done
  echo "ERROR: $c not healthy within 150s" >&2
  docker logs --tail 50 "$c" 2>&1 | sed 's/^/   | /' >&2 || true
  return 1
}
wait_healthy "${PROJECT}-web-1"
wait_healthy "${PROJECT}-meeting-service-1"

# 6. Event backbone is verified, not created (counts: 42 topics, 21 subjects). See deploy.sh.
topics="$("${COMPOSE[@]}" exec -T redpanda rpk topic list 2>/dev/null | tail -n +2 | grep -cvE '^(_schemas|__consumer_offsets|_redpanda)' || true)"
subjects="$("${COMPOSE[@]}" exec -T redpanda curl -sf http://localhost:8081/subjects 2>/dev/null | grep -o '"' | wc -l || true)"
subjects=$(( subjects / 2 ))
echo "   topics: ${topics}/42   subjects: ${subjects}/21"
if [[ "${topics:-0}" -lt 42 || "${subjects:-0}" -lt 21 ]]; then
  die "event backbone not provisioned (see mytheus-events scripts/create_topics.sh)"
fi

"${COMPOSE[@]}" ps
log "Deploy complete"
