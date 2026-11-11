#!/usr/bin/env bash
# Copy selected secrets from the local .env files to the server's secrets directory over SSH.
#
#   scripts/push-secrets.sh            # what the RUNNING stack needs now: LiveKit into prod.env
#   scripts/push-secrets.sh all        # also stage the AI and realtime tiers (Deepgram, R2, ...)
#   scripts/push-secrets.sh agents     # stage the Plan 7 agent tier: Anthropic key + a fresh
#                                      # billing caller token (prod.agents.env + prod.env)
#   scripts/push-secrets.sh polish     # polish plan wave 1: service-to-service tokens for the
#                                      # index guard, bff -> rag, core-api -> notification, and
#                                      # the capture secret. Generated ON the server, idempotent
#                                      # (an entry that exists is kept), backed up first.
#   scripts/push-secrets.sh --dry-run  # print file and key NAMES only; touch nothing
#
# Values travel over SSH stdin: they are never printed, never put in a command line, never logged.
# Run it from your own machine. A key that is empty or still a placeholder aborts the run.
set -euo pipefail

HOST="${MYTHEUS_HOST:-root@187.127.190.246}"
DIR="/etc/dokploy/mytheus-secrets/env"
ROOT="${MYTHEUS_ROOT:-$HOME/Projects/Mytheus}"
BACKEND="$ROOT/mytheus-backend/.env"
TRANSCRIPTION="$ROOT/mytheus-realtime/services/transcription-service/.env"
INTELLIGENCE="${MYTHEUS_INTELLIGENCE_ENV:-$ROOT/mytheus-intelligence/.env}"

MODE="live"; DRY=0
for a in "$@"; do
  case "$a" in all) MODE="all" ;; agents) MODE="agents" ;; polish) MODE="polish" ;; --dry-run) DRY=1 ;; *) echo "unknown argument: $a" >&2; exit 2 ;; esac
done

# value FILE KEY -> prints the value, or aborts when it is missing, empty or a placeholder.
value() {
  local v; v="$(grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2- || true)"
  if [ -z "$v" ] || [[ "$v" == *...* ]] || [[ "$v" == *"<"* ]]; then
    echo "abort: $2 is empty or a placeholder in $1" >&2; exit 1
  fi
  printf '%s' "$v"
}

# push TARGET_FILE  < KEY=VALUE lines. Replaces any existing line for each key, keeps mode 0600.
push() {
  local target="$1" lines; lines="$(cat)"
  local names; names="$(printf '%s\n' "$lines" | cut -d= -f1 | tr '\n' ' ')"
  if [ "$DRY" = 1 ]; then echo "would write $target: $names"; return; fi
  printf '%s\n' "$lines" | ssh "$HOST" '
    set -e
    f="'"$DIR"'/'"$target"'"; umask 077; touch "$f"
    tmp="$(mktemp)"; cat > "$tmp"
    while IFS= read -r l; do k="${l%%=*}"; sed -i "/^${k}=/d" "$f"; done < "$tmp"
    cat "$tmp" >> "$f"; n="$(wc -l < "$tmp")"; rm -f "$tmp"; chmod 600 "$f"
    echo "wrote $f ($n keys)"'
}

if [ "$MODE" = "agents" ]; then
  # Read and validate EVERYTHING first, at top level, so a missing key aborts before any file
  # on the server is touched (an abort inside a piped group would only end that subshell).
  anthropic="$(value "$INTELLIGENCE" ANTHROPIC_API_KEY)"
  # Optional: only needed when the key is not scoped to a workspace.
  ws="$(grep -m1 '^ANTHROPIC_WORKSPACE_ID=' "$INTELLIGENCE" 2>/dev/null | cut -d= -f2- || true)"
  # One shared secret, generated here and never printed: billing-metering-service reads the
  # caller list from prod.env, agent-runtime presents its entry from prod.agents.env.
  token="$(openssl rand -hex 32)"
  {
    printf 'BILLING_SERVICE_TOKEN=%s
' "$token"
    printf 'ANTHROPIC_API_KEY=%s
' "$anthropic"
    if [ -n "$ws" ]; then printf 'ANTHROPIC_WORKSPACE_ID=%s
' "$ws"; fi
  } | push prod.agents.env
  printf 'MYTHEUS_BILLING_CALLER_TOKENS=agent-runtime-service=%s
' "$token" | push prod.env
  echo "done. Enable the profiles on the host (COMPOSE_PROFILES=workers,agents,realtime) and redeploy."
  exit 0
fi

if [ "$MODE" = "polish" ]; then
  if [ "$DRY" = 1 ]; then
    echo "would write prod.env: MYTHEUS_CORE_CALLER_TOKENS(+embedding-service,+search-service) MYTHEUS_BILLING_CALLER_TOKENS(+embedding-service,+search-service) MYTHEUS_RAG_CALLER_TOKENS(+bff,+core-api,+integration-service) MYTHEUS_NOTIFICATION_CALLER_TOKENS(+core-api) MYTHEUS_MEETING_CALLER_TOKENS(+core-api) RAG_SERVICE_URL NOTIFICATION_SERVICE_URL"
    echo "would write prod.embedding.env, prod.search.env: CORE_CALLER_TOKEN BILLING_SERVICE_TOKEN ANTHROPIC_API_KEY ANTHROPIC_WORKSPACE_ID"
    echo "would write prod.rag.env: MYTHEUS_RAG_CALLER_TOKENS(+bff,+core-api,+integration-service)"
    echo "would write prod.transcription.env: CAPTURE_TOKEN_SECRET CAPTURE_ALLOWED_ORIGINS (extension + phone)"
    echo "would write prod.ui.env: CAPTURE_TOKEN_SECRET CAPTURE_INGEST_URL"
    echo "would write prod.env (core-api, the phone's in-person capture): CAPTURE_TOKEN_SECRET CAPTURE_INGEST_URL"
    exit 0
  fi
  # Everything happens on the server: the secrets are generated there and never cross this
  # machine, the Anthropic key is copied from prod.agents.env, and nothing is echoed but names.
  ssh "$HOST" "DIR='$DIR' bash -s" <<'REMOTE'
set -euo pipefail
cd "$DIR"; umask 077
ts=$(date +%Y%m%d%H%M%S); mkdir -p "/root/env-backups/$ts"; cp -a ./*.env "/root/env-backups/$ts/"
gen() { openssl rand -hex 32; }
entry() { grep "^$2=" "$1" 2>/dev/null | cut -d= -f2- | tr , '\n' | grep "^$3=" | cut -d= -f2- || true; }
# add NAME=VALUE to the comma list KEY in FILE; an existing entry for NAME is kept
add() { local f=$1 k=$2 n=$3 v=$4; touch "$f"
  if [ -n "$(entry "$f" "$k" "$n")" ]; then echo "kept $f $k:$n"; return; fi
  if grep -q "^$k=" "$f"; then sed -i "s|^$k=\(.*\)\$|$k=\1,$n=$v|" "$f"; else echo "$k=$n=$v" >> "$f"; fi
  echo "set  $f $k:$n"; }
# set KEY=VALUE in FILE unless KEY already has a value
put() { local f=$1 k=$2 v=$3; touch "$f"
  if [ -n "$(grep "^$k=" "$f" | cut -d= -f2- || true)" ]; then echo "kept $f $k"; return; fi
  sed -i "/^$k=/d" "$f"; echo "$k=$v" >> "$f"; echo "set  $f $k"; }
anthropic=$(grep -m1 '^ANTHROPIC_API_KEY=' prod.agents.env | cut -d= -f2-)
ws=$(grep -m1 '^ANTHROPIC_WORKSPACE_ID=' prod.agents.env | cut -d= -f2- || true)
[ -n "$anthropic" ] || { echo "abort: ANTHROPIC_API_KEY missing in prod.agents.env" >&2; exit 1; }
for svc in embedding search; do
  add prod.env MYTHEUS_CORE_CALLER_TOKENS "$svc-service" "$(gen)"
  add prod.env MYTHEUS_BILLING_CALLER_TOKENS "$svc-service" "$(gen)"
  put "prod.$svc.env" CORE_CALLER_TOKEN "$(entry prod.env MYTHEUS_CORE_CALLER_TOKENS "$svc-service")"
  put "prod.$svc.env" BILLING_SERVICE_TOKEN "$(entry prod.env MYTHEUS_BILLING_CALLER_TOKENS "$svc-service")"
  put "prod.$svc.env" ANTHROPIC_API_KEY "$anthropic"
  [ -z "$ws" ] || put "prod.$svc.env" ANTHROPIC_WORKSPACE_ID "$ws"
done
add prod.rag.env MYTHEUS_RAG_CALLER_TOKENS bff "$(gen)"
add prod.env MYTHEUS_RAG_CALLER_TOKENS bff "$(entry prod.rag.env MYTHEUS_RAG_CALLER_TOKENS bff)"
# Beyond the meeting: core-api asks rag-service to check text against decisions, and
# integration-service asks it to find promises in a Slack message. Each presents its own entry
# (from prod.env); rag-service accepts them (prod.rag.env).
for caller in core-api integration-service; do
  add prod.rag.env MYTHEUS_RAG_CALLER_TOKENS "$caller" "$(gen)"
  add prod.env MYTHEUS_RAG_CALLER_TOKENS "$caller" "$(entry prod.rag.env MYTHEUS_RAG_CALLER_TOKENS "$caller")"
done
put prod.env RAG_SERVICE_URL http://rag-service:8107
add prod.env MYTHEUS_NOTIFICATION_CALLER_TOKENS core-api "$(gen)"
# core-api -> meeting-service (off the record pauses the recording; erasure and clip videos):
# meeting-service accepts core-api's entry, core-api presents it (both read prod.env).
add prod.env MYTHEUS_MEETING_CALLER_TOKENS core-api "$(gen)"
put prod.env NOTIFICATION_SERVICE_URL http://notification-service:8000
cap=$(grep -m1 '^CAPTURE_TOKEN_SECRET=' prod.transcription.env | cut -d= -f2- || true); [ -n "$cap" ] || cap=$(gen)
put prod.transcription.env CAPTURE_TOKEN_SECRET "$cap"
# Not a secret, so always (re)written: the extension's origin and the phone app's.
sed -i "/^CAPTURE_ALLOWED_ORIGINS=/d" prod.transcription.env
echo "CAPTURE_ALLOWED_ORIGINS=chrome-extension://hcojignndmihgefeheffdnpaimncfglf,mytheus-mobile://capture" >> prod.transcription.env
echo "set  prod.transcription.env CAPTURE_ALLOWED_ORIGINS"
put prod.ui.env CAPTURE_TOKEN_SECRET "$cap"
put prod.ui.env CAPTURE_INGEST_URL wss://api.mytheus.cloud/capture/audio
# core-api mints the phone's in-person capture tokens (wave 3), with the same secret.
put prod.env CAPTURE_TOKEN_SECRET "$cap"
put prod.env CAPTURE_INGEST_URL wss://api.mytheus.cloud/capture/audio
chmod 600 ./*.env
[ "$(entry prod.env MYTHEUS_RAG_CALLER_TOKENS bff)" = "$(entry prod.rag.env MYTHEUS_RAG_CALLER_TOKENS bff)" ] || { echo "MISMATCH bff rag token" >&2; exit 1; }
[ "$(grep ^CAPTURE_TOKEN_SECRET= prod.ui.env)" = "$(grep ^CAPTURE_TOKEN_SECRET= prod.transcription.env)" ] || { echo "MISMATCH capture secret" >&2; exit 1; }
[ "$(grep ^CAPTURE_TOKEN_SECRET= prod.env)" = "$(grep ^CAPTURE_TOKEN_SECRET= prod.transcription.env)" ] || { echo "MISMATCH capture secret (core-api)" >&2; exit 1; }
echo "ok (backup in /root/env-backups/$ts)"
REMOTE
  echo "done. Redeploy backend, intelligence, realtime and ui so they read the new values."
  exit 0
fi

# Needed by the running stack: meeting-service mints LiveKit tokens from prod.env.
for k in LIVEKIT_URL LIVEKIT_API_KEY LIVEKIT_API_SECRET; do
  printf '%s=%s\n' "$k" "$(value "$BACKEND" "$k")"
done | push prod.env

if [ "$MODE" = "all" ]; then
  printf 'INTERNAL_AUDIO_TOKEN=%s\n' "$(value "$TRANSCRIPTION" INTERNAL_AUDIO_TOKEN)" | push prod.audio-tap.env
  # The same token on BOTH ends: audio-tap-worker presents it, transcription-service checks it.
  # It used to reach only prod.audio-tap.env, so transcription refused every tap connection.
  for k in INTERNAL_AUDIO_TOKEN DEEPGRAM_API_KEY LIVEKIT_URL LIVEKIT_API_KEY LIVEKIT_API_SECRET; do
    printf '%s=%s\n' "$k" "$(value "$TRANSCRIPTION" "$k")"
  done | push prod.transcription.env
  for k in S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY; do
    printf '%s=%s\n' "$k" "$(value "$INTELLIGENCE" "$k")"
  done | push prod.ingestion.env
  {
    printf 'S3_ENDPOINT_URL=%s\n' "$(value "$INTELLIGENCE" S3_ENDPOINT_URL)"
    printf 'S3_REGION=auto\nS3_BUCKET_DOCUMENTS=mytheus-documents\nS3_AUTO_CREATE_BUCKETS=0\n'
  } | push prod.platform.env
  printf 'CLERK_JWKS_URL=%s\n' "$(value "$BACKEND" CLERK_JWKS_URL)" | push prod.realtime.env
fi
echo "done. Redeploy so the services read the new values."
