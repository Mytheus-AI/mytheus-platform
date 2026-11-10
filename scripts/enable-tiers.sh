#!/usr/bin/env bash
# Switch on every optional tier on the production VPS: workers, realtime, agents, intelligence.
# Runs ON the server, as root. From your machine, after scripts/push-secrets.sh all + agents:
#
#   ssh root@187.127.190.246 'bash -s' < scripts/enable-tiers.sh             # do it
#   ssh root@187.127.190.246 'bash -s -- --dry-run' < scripts/enable-tiers.sh  # look only
#
# Idempotent: a credential file that already has a value is kept, never regenerated (a new
# password would lock the running services out). Generated values are never printed.
#
# What it does, in order (any failure stops it before the stack is touched):
#   1. Finds the live compose project from the running web container's labels, so it does not
#      depend on where the checkout lives, and fast-forwards that checkout.
#   2. Writes the tier credential files that can be derived on the server:
#        prod.db.core-consumer.env, prod.db.meeting-consumer.env  -> the mytheus_app URL
#        prod.transcription.env DATABASE_URL                       -> the mytheus_app URL
#        prod.db.ai.env, prod.db.ai-relay.env                      -> fresh role passwords
#        prod.qdrant.env, prod.embedding.env, prod.search.env      -> fresh write/read keys
#        prod.platform.env                                         -> the in-network addresses
#      and checks the ones push-secrets.sh must already have staged.
#   3. Runs both tier migrations, then gives mytheus_ai_app / mytheus_ai_relay their passwords.
#   4. Sets COMPOSE_PROFILES in the project's .env, syncs the Caddy fragment (validate first,
#      restore on failure), and brings the stack up.
set -euo pipefail

DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1
PROFILES="${MYTHEUS_PROFILES:-workers,realtime,agents,intelligence}"
ENV_DIR="${MYTHEUS_ENV_DIR:-/etc/dokploy/mytheus-secrets/env}"

log() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
run() { if [[ $DRY == 1 ]]; then echo "   (dry-run) $*"; else "$@"; fi; }

# --- 1. locate the live project ---------------------------------------------------------------
web="$(docker ps --filter label=com.docker.compose.service=web --format '{{.Names}}' | head -1)"
[[ -n "$web" ]] || die "no running compose 'web' container: is the mytheus stack up?"
label() { docker inspect -f "{{ index .Config.Labels \"$1\" }}" "$web"; }
PROJECT="$(label com.docker.compose.project)"
WORKDIR="$(label com.docker.compose.project.working_dir)"
CONFIGS="$(label com.docker.compose.project.config_files)"
log "project=$PROJECT workdir=$WORKDIR"
COMPOSE=(docker compose -p "$PROJECT" --project-directory "$WORKDIR")
IFS=',' read -ra cfgs <<<"$CONFIGS"
for f in "${cfgs[@]}"; do COMPOSE+=(-f "$f"); done

repo="$(git -C "$WORKDIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -n "$repo" ]]; then
  log "fast-forwarding $repo"
  # Best effort: root's own SSH key may not reach GitHub (the deploy uses its own deploy key,
  # and every deploy already fast-forwards this checkout), so a failed fetch only warns.
  if [[ $DRY == 0 ]] && ! { git -C "$repo" fetch -q origin main && git -C "$repo" merge -q --ff-only origin/main; }; then
    echo "   warning: could not fast-forward; continuing on $(git -C "$repo" log --oneline -1)"
  fi
fi

# --- 2. credential files ---------------------------------------------------------------------
[[ -s "$ENV_DIR/prod.db.app.env" && -s "$ENV_DIR/prod.db.migrate.env" ]] \
  || die "prod.db.app.env / prod.db.migrate.env missing in $ENV_DIR"
umask 077
get() { grep -m1 "^$2=" "$ENV_DIR/$1" 2>/dev/null | cut -d= -f2- || true; }
# put FILE KEY VALUE: only when the key is absent or empty. Returns 0 if it wrote.
put() {
  local f="$ENV_DIR/$1"
  [[ -n "$(get "$1" "$2")" ]] && return 1
  if [[ $DRY == 1 ]]; then echo "   (dry-run) would set $2 in $1"; return 0; fi
  touch "$f"; sed -i "/^$2=/d" "$f"; printf '%s=%s\n' "$2" "$3" >>"$f"; chmod 600 "$f"
  echo "   set $2 in $1"
}
rand() { openssl rand -hex 24; }

APP_URL="$(get prod.db.app.env DATABASE_URL)"
[[ "$APP_URL" == postgresql* ]] || die "prod.db.app.env has no postgresql DATABASE_URL"
put prod.db.core-consumer.env DATABASE_URL "$APP_URL" || true
put prod.db.meeting-consumer.env DATABASE_URL "$APP_URL" || true
put prod.transcription.env DATABASE_URL "$APP_URL" || true
# audio-tap-worker resolves the room to its meeting through the shared DB session, so it needs
# a DATABASE_URL despite the "no DB" note in the compose file.
put prod.audio-tap.env DATABASE_URL "$APP_URL" || true

# The AI roles get a new password only when their file has none. Step 3 then applies whatever
# the file holds to the role every run, so a file written before the role existed still takes.
if [[ -z "$(get prod.db.ai.env DATABASE_URL)" ]]; then
  put prod.db.ai.env DATABASE_URL "postgresql+asyncpg://mytheus_ai_app:$(rand)@postgres:5432/mytheus"
fi
if [[ -z "$(get prod.db.ai-relay.env DATABASE_URL)" ]]; then
  put prod.db.ai-relay.env DATABASE_URL "postgresql+asyncpg://mytheus_ai_relay:$(rand)@postgres:5432/mytheus"
fi
# embedding-relay reads RELAY_DATABASE_URL (relay_main.py) and otherwise falls back to a
# localhost dev default, so the same URL goes under that name too.
put prod.db.ai-relay.env RELAY_DATABASE_URL "$(get prod.db.ai-relay.env DATABASE_URL)" || true
pw_of() { local u; u="$(get "$1" DATABASE_URL)"; u="${u#*://}"; u="${u%%@*}"; printf '%s' "${u#*:}"; }

if [[ -z "$(get prod.qdrant.env QDRANT__SERVICE__API_KEY)" ]]; then
  w="$(rand)"; r="$(rand)"
  put prod.qdrant.env QDRANT__SERVICE__API_KEY "$w"
  put prod.qdrant.env QDRANT__SERVICE__READ_ONLY_API_KEY "$r"
  put prod.embedding.env QDRANT_API_KEY "$w" || true
  put prod.search.env QDRANT_READ_ONLY_API_KEY "$r" || true
fi

# The knowledge graph (profile kg, mytheus-docs ADR-0031): the AGE container's superuser, the
# worker/API's AGE_DATABASE_URL, and the one caller token bff presents to the read API. bff
# reads prod.env; the graph services read prod.kg.env and never prod.env.
if [[ -z "$(get prod.age.env POSTGRES_PASSWORD)" ]]; then
  p="$(rand)"
  put prod.age.env POSTGRES_USER nexus_graph
  put prod.age.env POSTGRES_PASSWORD "$p"
  put prod.age.env POSTGRES_DB nexus_graph
  put prod.kg.env AGE_DATABASE_URL "postgresql://nexus_graph:$p@age:5432/nexus_graph" || true
fi
if [[ -z "$(get prod.env MYTHEUS_KG_SERVICE_TOKEN)" ]]; then
  t="$(rand)"
  put prod.env MYTHEUS_KG_SERVICE_TOKEN "$t"
  put prod.kg.env MYTHEUS_KG_CALLER_TOKENS "bff=$t" || true
fi

# meeting-service -> core-api room-state reports (mytheus-backend internal_meetings.py). Both
# services read prod.env, so one shared entry serves as core-api's allowlist and as
# meeting-service's own secret. Without it, meetings simply keep their status.
put prod.env MYTHEUS_CORE_CALLER_TOKENS "meeting-service=$(rand)" || true

# rag-service (mytheus-docs ADR-0033). It authenticates the asker itself, then calls every
# dependency as itself with ONE secret, RAG_SERVICE_TOKEN (prod.rag.env), which each callee lists
# under its own caller-tokens key: core-api (retrieval scope) and billing (budget read-through)
# in prod.env, knowledge-graph-service in prod.kg.env, search-grpc in prod.search.env,
# embedding-service in prod.embedding.env, reranker-service in prod.reranker.env. Its own
# allowlist, MYTHEUS_RAG_CALLER_TOKENS, admits agent-runtime-service (QuestionAgent grounding),
# whose secret goes to prod.agents.env as RAG_CALLER_TOKEN. The Anthropic key and the Qdrant
# READ-ONLY key are copied in so rag-service reads no other tier's file.
# add_caller FILE KEY NAME SECRET: make NAME=SECRET the entry for NAME in a comma-separated
# allowlist, leaving every other caller's entry as it is. An up-to-date entry is a no-op; a stale
# one (push-secrets.sh rewrote a list, or a token was regenerated) is replaced. Never printed.
add_caller() {
  local f="$ENV_DIR/$1" cur rest="" e
  cur="$(get "$1" "$2")"
  [[ ",$cur," == *",$3=$4,"* ]] && return 0
  IFS=',' read -ra entries <<<"$cur"
  for e in "${entries[@]}"; do [[ -n "$e" && "$e" != "$3="* ]] && rest="${rest:+$rest,}$e"; done
  if [[ $DRY == 1 ]]; then echo "   (dry-run) would set $3 in $2 in $1"; return 0; fi
  touch "$f"; sed -i "/^$2=/d" "$f"
  printf '%s=%s\n' "$2" "${rest:+$rest,}$3=$4" >>"$f"; chmod 600 "$f"
  echo "   set $3 in $2 in $1"
}
put prod.rag.env RAG_SERVICE_TOKEN "$(rand)" || true
rag_token="$(get prod.rag.env RAG_SERVICE_TOKEN)"
if [[ -n "$rag_token" ]]; then
  add_caller prod.env MYTHEUS_CORE_CALLER_TOKENS rag-service "$rag_token"
  add_caller prod.env MYTHEUS_BILLING_CALLER_TOKENS rag-service "$rag_token"
  add_caller prod.kg.env MYTHEUS_KG_CALLER_TOKENS rag-service "$rag_token"
  add_caller prod.search.env MYTHEUS_SEARCH_CALLER_TOKENS rag-service "$rag_token"
  add_caller prod.embedding.env MYTHEUS_EMBED_CALLER_TOKENS rag-service "$rag_token"
  add_caller prod.reranker.env MYTHEUS_RERANK_CALLER_TOKENS rag-service "$rag_token"
fi
# workflow-service (P10 MeetingLifecycleWorkflow activities) calls core-api and meeting-service
# internal routes as itself. One secret, kept in prod.env, listed in both allowlists.
put prod.env MYTHEUS_WORKFLOW_SERVICE_TOKEN "$(rand)" || true
wf_token="$(get prod.env MYTHEUS_WORKFLOW_SERVICE_TOKEN)"
if [[ -n "$wf_token" ]]; then
  add_caller prod.env MYTHEUS_CORE_CALLER_TOKENS workflow-service "$wf_token"
  add_caller prod.env MYTHEUS_MEETING_CALLER_TOKENS workflow-service "$wf_token"
fi
# ContextGapAgent (P10, mytheus-docs ADR-0035): the HMAC secret behind the signed agent identity
# (32+ chars; without it A2A is off and the agent uses RAG only), and its own core-api caller
# token for the related-meeting hop (GET /internal/meetings/{id}/related-attendees).
put prod.agents.env AGENT_IDENTITY_SECRET "$(rand)" || true
put prod.agents.env CORE_URL "http://core-api:8000" || true
put prod.agents.env CORE_CALLER_TOKEN "$(rand)" || true
agent_core="$(get prod.agents.env CORE_CALLER_TOKEN)"
[[ -n "$agent_core" ]] && add_caller prod.env MYTHEUS_CORE_CALLER_TOKENS agent-runtime-service "$agent_core"
put prod.agents.env RAG_CALLER_TOKEN "$(rand)" || true
put prod.agents.env RAG_URL "http://rag-service:8107" || true
agent_rag="$(get prod.agents.env RAG_CALLER_TOKEN)"
[[ -n "$agent_rag" ]] && add_caller prod.rag.env MYTHEUS_RAG_CALLER_TOKENS agent-runtime-service "$agent_rag"
put prod.rag.env QDRANT_READ_ONLY_API_KEY "$(get prod.search.env QDRANT_READ_ONLY_API_KEY)" || true
put prod.rag.env ANTHROPIC_API_KEY "$(get prod.agents.env ANTHROPIC_API_KEY)" || true
ws="$(get prod.agents.env ANTHROPIC_WORKSPACE_ID)"
[[ -n "$ws" ]] && { put prod.rag.env ANTHROPIC_WORKSPACE_ID "$ws" || true; }

put prod.platform.env REDIS_URL "redis://redis:6379/0" || true
put prod.platform.env REDPANDA_BROKERS "redpanda:29092" || true
put prod.platform.env SCHEMA_REGISTRY_URL "http://redpanda:8081" || true
put prod.platform.env QDRANT_URL "http://qdrant:6333" || true

# Staged from your machine by push-secrets.sh. Missing ones mean it was not run (or failed).
missing=()
need() { [[ -n "$(get "$1" "$2")" ]] || missing+=("$1:$2"); }
need prod.env LIVEKIT_API_SECRET
need prod.audio-tap.env INTERNAL_AUDIO_TOKEN
need prod.transcription.env INTERNAL_AUDIO_TOKEN
need prod.transcription.env DEEPGRAM_API_KEY
need prod.realtime.env CLERK_JWKS_URL
need prod.ingestion.env S3_ACCESS_KEY_ID
need prod.platform.env S3_ENDPOINT_URL
need prod.agents.env ANTHROPIC_API_KEY
need prod.env MYTHEUS_BILLING_CALLER_TOKENS
if ((${#missing[@]})); then
  [[ $DRY == 1 ]] && { echo "   (dry-run) still missing: ${missing[*]}"; } \
    || die "not staged yet (run scripts/push-secrets.sh all, then agents): ${missing[*]}"
fi

# --- 3. migrations, then role passwords -------------------------------------------------------
export COMPOSE_PROFILES="$PROFILES"
has() { [[ ",$PROFILES," == *",$1,"* ]]; }
log "running tier migrations"
if has realtime; then
  run "${COMPOSE[@]}" pull -q migrate-transcription
  run "${COMPOSE[@]}" run --rm --no-deps -T migrate-transcription </dev/null
fi
if has intelligence; then
  run "${COMPOSE[@]}" pull -q migrate-intelligence
  run "${COMPOSE[@]}" run --rm --no-deps -T migrate-intelligence </dev/null
fi

if has intelligence; then
  log "applying AI role passwords"
  sql="ALTER ROLE mytheus_ai_app PASSWORD '$(pw_of prod.db.ai.env)';"
  sql+="ALTER ROLE mytheus_ai_relay PASSWORD '$(pw_of prod.db.ai-relay.env)';"
  # Over stdin, so the passwords never appear in a process list or the shell history.
  if [[ $DRY == 1 ]]; then echo "   (dry-run) would ALTER ROLE the AI roles"; else
    # As the schema owner from prod.db.migrate.env (it holds CREATEROLE). The password goes in
    # through the environment (`-e PGPASSWORD` with no value), not the command line.
    owner_url="$(get prod.db.migrate.env BOOTSTRAP_DATABASE_URL)"
    [[ -n "$owner_url" ]] || owner_url="$(get prod.db.migrate.env DATABASE_URL)"
    creds="${owner_url#*://}"; creds="${creds%%@*}"
    PGUSER_OWNER="${creds%%:*}"; export PGPASSWORD="${creds#*:}"
    printf '%s\n' "$sql" | "${COMPOSE[@]}" exec -T -e PGPASSWORD postgres \
      psql -v ON_ERROR_STOP=1 -q -h 127.0.0.1 -U "$PGUSER_OWNER" -d mytheus
    unset PGPASSWORD
  fi
fi

# --- 4. profiles, Caddy, up -------------------------------------------------------------------
envfile="$WORKDIR/.env"
log "COMPOSE_PROFILES=$PROFILES in $envfile"
if [[ $DRY == 0 ]]; then
  touch "$envfile"; sed -i '/^COMPOSE_PROFILES=/d' "$envfile"; echo "COMPOSE_PROFILES=$PROFILES" >>"$envfile"
fi

caddy="$(docker ps --format '{{.Names}}' | while read -r c; do
  # `|| true`: under pipefail a container without the mount would otherwise end the script.
  if docker inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' "$c" | grep -q '/etc/caddy/conf.d'; then echo "$c"; fi
done | head -1 || true)"
frag="${repo:-$WORKDIR/..}/deploy/caddy/mytheus.caddy"
if [[ -n "$caddy" && -f "$frag" ]]; then
  confd="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/caddy/conf.d"}}{{.Source}}{{end}}{{end}}' "$caddy")"
  log "syncing Caddy fragment into $confd (container $caddy)"
  if [[ $DRY == 0 ]]; then
    backup="$(mktemp)"; cp -p "$confd/mytheus.caddy" "$backup" 2>/dev/null || : >"$backup"
    cp "$frag" "$confd/mytheus.caddy"
    if docker exec "$caddy" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
      docker exec "$caddy" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
    else
      cp -p "$backup" "$confd/mytheus.caddy"; die "Caddy validation failed; old fragment restored"
    fi
  fi
else
  echo "   no Caddy container with a conf.d mount found: sync the fragment by hand"
fi

log "bringing the stack up with $PROFILES"
run "${COMPOSE[@]}" up -d --pull always
[[ $DRY == 0 ]] && { sleep 20; "${COMPOSE[@]}" ps --format 'table {{.Service}}\t{{.Status}}'; }
log "done"
