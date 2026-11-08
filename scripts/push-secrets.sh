#!/usr/bin/env bash
# Copy selected secrets from the local .env files to the server's secrets directory over SSH.
#
#   scripts/push-secrets.sh            # what the RUNNING stack needs now: LiveKit into prod.env
#   scripts/push-secrets.sh all        # also stage the AI and realtime tiers (Deepgram, R2, ...)
#   scripts/push-secrets.sh agents     # stage the Plan 7 agent tier: Anthropic key + a fresh
#                                      # billing caller token (prod.agents.env + prod.env)
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
  case "$a" in all) MODE="all" ;; agents) MODE="agents" ;; --dry-run) DRY=1 ;; *) echo "unknown argument: $a" >&2; exit 2 ;; esac
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
