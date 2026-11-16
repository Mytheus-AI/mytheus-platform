#!/usr/bin/env bash
# Turn on authentication for Redis and Redpanda (journal cross-store study, chains R1, R2, K1, K2).
# Runs ON THE VPS; pipe it over SSH from your machine:
#
#   ssh root@187.127.190.246 'bash -s' < scripts/enable-store-auth.sh             # enable
#   ssh root@187.127.190.246 'bash -s -- check' < scripts/enable-store-auth.sh    # verify only
#   ssh root@187.127.190.246 'bash -s -- rollback' < scripts/enable-store-auth.sh # undo
#
# Before running: this repo's compose change (redis/redpanda read prod.redis.env and
# prod.redpanda.env; intelligence and realtime services read prod.store.<tier>.env) and the
# kafka_auth client change in mytheus-backend, -intelligence and -realtime must be deployed.
# The script checks both and stops if either is missing.
#
# What it does (idempotent; secrets are generated here and never printed):
#   1. Generates passwords into prod.store-auth.secrets (root only, loaded by nothing).
#   2. Creates the SCRAM principals admin (superuser), backend, intelligence and realtime, and the
#      ACLs: each principal may use every topic and group, except that only `backend` may WRITE
#      the confirmed-intent topics `decisions` and `actions` (core-api is their only producer).
#   3. Writes each tier's client settings: prod.env (backend), prod.store.intelligence.env,
#      prod.store.realtime.env; and prod.redis.env / prod.redpanda.env for the two stores.
#   4. Turns on Kafka SASL and admin-API auth (cluster properties), then recreates every running
#      container of the stack so all of it picks the settings up together (about a minute in
#      which events wait in the clients' retry buffers).
#   5. Verifies: anonymous Redis, Kafka, admin API and Schema Registry access are all refused,
#      and every container that was healthy before is healthy again.
set -euo pipefail

MODE="${1:-enable}"
ENV_DIR="${MYTHEUS_ENV_DIR:-/etc/dokploy/mytheus-secrets/env}"
SECRETS="$ENV_DIR/prod.store-auth.secrets"
PROJECT="${MYTHEUS_PROJECT:-mytheus}"
STAMP="$(date +%Y%m%d%H%M%S)"

say() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
cid() { docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=$1" | head -1; }

RP="$(cid redpanda)"; RD="$(cid redis)"
[ -n "$RP" ] && [ -n "$RD" ] || die "redpanda/redis containers of project $PROJECT not found"

# compose invocation, taken from the running stack's own labels (the deploy's exact files)
WD="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$RP")"
CF="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$RP")"
COMPOSE=(docker compose -p "$PROJECT"); IFS=, read -ra _f <<< "$CF"; for f in "${_f[@]}"; do COMPOSE+=(-f "$f"); done

# setkey FILE KEY VALUE: replace or append KEY=VALUE, mode 0600, value never echoed
setkey() {
  local f="$1" k="$2" v="$3"; umask 077; touch "$f"
  local tmp; tmp="$(mktemp)"; grep -v "^$k=" "$f" > "$tmp" || true
  printf '%s=%s\n' "$k" "$v" >> "$tmp"; cat "$tmp" > "$f"; rm -f "$tmp"; chmod 600 "$f"
}
getkey() { grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2- || true; }
gen() { openssl rand -hex 24; }
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

running_services() {
  docker ps --filter "label=com.docker.compose.project=$PROJECT" \
    --format '{{.Label "com.docker.compose.service"}}' | sort -u
}

recreate_all() {
  local svcs; svcs="$(running_services | tr '\n' ' ')"
  say "recreating: $svcs"
  # shellcheck disable=SC2086
  (cd "$WD" && "${COMPOSE[@]}" up -d --no-deps $svcs)
}

wait_healthy() {
  say "waiting for every container to be healthy (up to 4 min)"
  local i bad
  for i in $(seq 1 48); do
    bad="$(docker ps --filter "label=com.docker.compose.project=$PROJECT" \
      --format '{{.Label "com.docker.compose.service"}} {{.Status}}' | grep -E 'starting|unhealthy|Restarting' || true)"
    [ -z "$bad" ] && { say "all healthy"; return 0; }
    sleep 5
  done
  echo "$bad" >&2; return 1
}

check() {
  local ok=1 pass rpass
  pass="$(getkey "$ENV_DIR/prod.redis.env" REDIS_PASSWORD)"
  RD="$(cid redis)"; RP="$(cid redpanda)"
  if docker exec "$RD" redis-cli ping 2>&1 | grep -q PONG; then echo "FAIL redis answers without a password"; ok=0; else echo "ok   redis refuses anonymous clients"; fi
  if [ -n "$pass" ] && docker exec -e REDISCLI_AUTH="$pass" "$RD" redis-cli ping | grep -q PONG; then echo "ok   redis accepts the password"; else echo "FAIL redis rejects the password"; ok=0; fi
  if docker exec "$RP" env -u RPK_USER -u RPK_PASS -u RPK_SASL_MECHANISM rpk topic list -X brokers=localhost:29092 >/dev/null 2>&1; then echo "FAIL kafka lists topics anonymously"; ok=0; else echo "ok   kafka refuses anonymous clients"; fi
  if docker exec "$RP" rpk topic list >/dev/null 2>&1; then echo "ok   kafka accepts the admin principal"; else echo "FAIL admin principal rejected"; ok=0; fi
  code="$(docker exec "$RP" curl -s -o /dev/null -w '%{http_code}' localhost:9644/v1/cluster_config 2>/dev/null || echo 000)"
  [ "$code" = 401 ] || [ "$code" = 403 ] && echo "ok   admin API refuses anonymous ($code)" || { echo "FAIL admin API answered $code"; ok=0; }
  code="$(docker exec "$RP" curl -s -o /dev/null -w '%{http_code}' localhost:8081/subjects 2>/dev/null || echo 000)"
  [ "$code" = 401 ] && echo "ok   schema registry refuses anonymous" || { echo "FAIL schema registry answered $code"; ok=0; }
  rpass="$(getkey "$SECRETS" KAFKA_PASSWORD_INTELLIGENCE)"
  if [ -n "$rpass" ]; then
    # produce as intelligence: allowed on agent-results, refused on decisions (rpk would retry a
    # refused write for minutes, so each probe has a 15 s delivery timeout)
    probe() { echo probe | docker exec -i "$RP" env -u RPK_USER -u RPK_PASS -u RPK_SASL_MECHANISM \
      rpk topic produce "$1" --delivery-timeout 15s -X brokers=localhost:29092 \
      -X user=intelligence -X pass="$rpass" -X sasl.mechanism=SCRAM-SHA-256 >/dev/null 2>&1; }
    if probe agent-results; then echo "ok   intelligence can write agent-results"; else echo "FAIL intelligence cannot write agent-results"; ok=0; fi
    if probe decisions; then echo "FAIL intelligence could write decisions"; ok=0; else echo "ok   intelligence cannot write decisions"; fi
  fi
  [ "$ok" = 1 ] && say "all checks passed" || die "some checks failed"
}

rollback() {
  say "rolling back store authentication"
  for f in prod.env prod.store.intelligence.env prod.store.realtime.env prod.redis.env prod.redpanda.env; do
    b="$(ls -1t "$ENV_DIR/$f".bak.store-auth.* 2>/dev/null | tail -1 || true)"   # the oldest = pre-enable
    if [ -n "$b" ]; then cp -p "$b" "$ENV_DIR/$f"; say "restored $f from $(basename "$b")"
    elif [ "$f" != prod.env ]; then rm -f "$ENV_DIR/$f"; say "removed $f"; fi
  done
  docker exec "$RP" rpk cluster config set enable_sasl false || true
  docker exec "$RP" rpk cluster config set admin_api_require_auth false || true
  recreate_all
  wait_healthy || die "stack not healthy after rollback; check docker ps"
  say "rolled back; Redis and Redpanda are open on the Docker network again"
}

[ "$MODE" = check ] && { check; exit 0; }
[ "$MODE" = rollback ] && { rollback; exit 0; }
[ "$MODE" = enable ] || die "usage: enable | check | rollback"

# --- preflight ---------------------------------------------------------------------------------
say "preflight"
grep -q REDPANDA_SASL "${_f[0]}" || die "the deployed compose file predates store auth: deploy mytheus-platform first"
for svc in relay agent-runtime realtime-gateway; do
  c="$(cid "$svc")"; [ -n "$c" ] || continue
  case "$svc" in
    realtime-gateway) docker exec "$c" sh -c 'find dist -name kafkaAuth.js | grep -q .' || die "$svc image predates kafkaAuth: deploy mytheus-realtime first" ;;
    *) docker exec "$c" python -c 'import libs.shared.kafka_auth' 2>/dev/null || die "$svc image predates kafka_auth: deploy it first" ;;
  esac
done
c="$(cid transcription-service)"; [ -z "$c" ] || docker exec "$c" python -c 'import transcription_service.kafka_auth' 2>/dev/null || die "transcription-service image predates kafka_auth: deploy mytheus-realtime first"
wait_healthy || die "the stack is not healthy before starting; fix that first"

# --- 1. secrets --------------------------------------------------------------------------------
say "secrets"
for k in KAFKA_PASSWORD_ADMIN KAFKA_PASSWORD_BACKEND KAFKA_PASSWORD_INTELLIGENCE KAFKA_PASSWORD_REALTIME REDIS_PASSWORD; do
  [ -n "$(getkey "$SECRETS" "$k")" ] || setkey "$SECRETS" "$k" "$(gen)"
done
ADMIN="$(getkey "$SECRETS" KAFKA_PASSWORD_ADMIN)"; REDIS_PW="$(getkey "$SECRETS" REDIS_PASSWORD)"

# --- 2. principals and ACLs (admin API and Kafka are still open at this point) -------------------
say "principals"
A=(-X user=admin -X pass="$ADMIN" -X sasl.mechanism=SCRAM-SHA-256)
user() { # create, or reset the password of, a SCRAM user
  if docker exec "$RP" rpk acl user create "$1" -p "$2" --mechanism SCRAM-SHA-256 >/dev/null 2>&1 \
    || docker exec "$RP" rpk acl user update "$1" --new-password "$2" --mechanism SCRAM-SHA-256 "${A[@]}" >/dev/null 2>&1; then
    echo "   user $1"
  else die "could not create user $1"; fi
}
user admin "$ADMIN"
for p in backend intelligence realtime; do user "$p" "$(getkey "$SECRETS" "KAFKA_PASSWORD_$(upper "$p")")"; done
docker exec "$RP" rpk cluster config set superusers '["admin"]' >/dev/null

say "ACLs"
for p in backend intelligence realtime; do
  docker exec "$RP" rpk acl create --allow-principal "User:$p" --operation all --topic '*' --group '*' --transactional-id '*' >/dev/null
  docker exec "$RP" rpk acl create --allow-principal "User:$p" --operation idempotent_write --cluster >/dev/null
done
for p in intelligence realtime; do
  docker exec "$RP" rpk acl create --deny-principal "User:$p" --operation write --topic decisions --topic actions >/dev/null
done

# --- 3. client settings ------------------------------------------------------------------------
say "client settings (backups: *.bak.store-auth.$STAMP)"
for f in prod.env prod.store.intelligence.env prod.store.realtime.env prod.redis.env prod.redpanda.env; do
  [ -f "$ENV_DIR/$f" ] && cp -p "$ENV_DIR/$f" "$ENV_DIR/$f.bak.store-auth.$STAMP"
done
url="redis://:${REDIS_PW}@redis:6379/0"
setkey "$ENV_DIR/prod.env" REDIS_URL "$url"
setkey "$ENV_DIR/prod.env" KAFKA_SASL_USERNAME backend
setkey "$ENV_DIR/prod.env" KAFKA_SASL_PASSWORD "$(getkey "$SECRETS" KAFKA_PASSWORD_BACKEND)"
for t in intelligence realtime; do
  setkey "$ENV_DIR/prod.store.$t.env" REDIS_URL "$url"
  setkey "$ENV_DIR/prod.store.$t.env" KAFKA_SASL_USERNAME "$t"
  setkey "$ENV_DIR/prod.store.$t.env" KAFKA_SASL_PASSWORD "$(getkey "$SECRETS" "KAFKA_PASSWORD_$(upper "$t")")"
done
setkey "$ENV_DIR/prod.redis.env" REDIS_PASSWORD "$REDIS_PW"
setkey "$ENV_DIR/prod.redpanda.env" REDPANDA_SASL 1
setkey "$ENV_DIR/prod.redpanda.env" RPK_USER admin
setkey "$ENV_DIR/prod.redpanda.env" RPK_PASS "$ADMIN"
setkey "$ENV_DIR/prod.redpanda.env" RPK_SASL_MECHANISM SCRAM-SHA-256

# --- 4. switch on and recreate -----------------------------------------------------------------
say "enabling Kafka SASL and admin-API auth"
docker exec "$RP" rpk cluster config set enable_sasl true >/dev/null
docker exec "$RP" rpk cluster config set admin_api_require_auth true "${A[@]}" >/dev/null
recreate_all
wait_healthy || { echo "not healthy: run this script with 'rollback' if it does not settle" >&2; exit 1; }

# --- 5. verify ---------------------------------------------------------------------------------
check
say "done. Backups of every changed env file end in .bak.store-auth.$STAMP"
