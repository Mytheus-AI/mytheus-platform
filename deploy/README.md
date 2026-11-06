# deploy/ — VPS deploy (modular monolith)

MVP deploy target: the `mytheus-backend` modular monolith + its data stores, self-hosted on the
existing VPS with Docker Compose. **No Kubernetes, no Terraform** in this band (those are post-W36,
Plan 14). The service seams are real; this co-locates them in one deployable.

## Target

- VPS host: **UNRESOLVED, see the TODO-for-owner note below** (two different hosts are recorded in this repo). Ubuntu, x86_64.
- One backend image runs three roles: `web` (uvicorn), `relay` (outbox drain, the only sanctioned
  producer), `workflow` (Temporal workers). The image is PULLED from
  `ghcr.io/mytheus-ai/mytheus-backend`, published by mytheus-backend CI; nothing is built here.
- Self-hosted `postgres`, `redis`, `redpanda` (Kafka API + Schema Registry), `temporal`.
- **No TLS terminator in this stack.** The box already runs the `atithivishram-prod` Caddy on
  80/443, which is the only listener the host's `cf-origin-lock` admits Cloudflare traffic to.
  That Caddy terminates `api.mytheus.cloud` and `vps.mytheus.cloud` and proxies to `web:8000`
  over the shared docker network, so this stack publishes no ports at all.

## Files

| File | Purpose |
| --- | --- |
| `compose.prod.yml` | the full stack (stores + backend roles) |
| `postgres-init/prod-bootstrap.sql` | one-shot post-init hook: sets the postgres password and makes it own `public` |
| `deploy.sh` | manual fallback bring-up: pull images, up, wait for health |
| `mytheus-deploy.sh` | **reviewed copy** of the VPS forced command `/usr/local/sbin/mytheus-deploy.sh` (gap 26); NOT yet adopted, see below |
| `compose.gpu.yml` | override: GPU image + NVIDIA reservation for embedding/reranker (CPU is the default) |
| `caddy/mytheus.caddy` | Mytheus site blocks for the shared Caddy (now also routes `/socket.io/*` to realtime-gateway) |
| `../observability/` | Prometheus config + alert rules, Grafana provisioning + dashboards |

## First-time setup on the VPS

```bash
# 1. Install Docker Engine + compose plugin (Ubuntu 24.04)
curl -fsSL https://get.docker.com | sh

# 2. Clone THIS repo only. mytheus-backend is no longer needed on the box: the backend
#    arrives as a published image. (Earlier revisions required both repos side by side
#    because compose built the backend from `context: ../../mytheus-backend`.)
mkdir -p /srv/mytheus && cd /srv/mytheus
git clone <mytheus-platform-url> mytheus-platform

# 2b. Authenticate to GHCR so the private backend image can be pulled.
#     Use a token scoped to read:packages ONLY — this credential sits on the server.
echo <READ_PACKAGES_TOKEN> | docker login ghcr.io -u <github-user> --password-stdin

# 3. Fill secrets (never committed). FOUR files, deliberately: the database credential is
#    split per process so `web` cannot read the schema-owner or operator credential. See the
#    header of env/prod.env.example for why (defect D1 had two halves; this is the second).
cd mytheus-platform
cp env/prod.env.example            env/prod.env
cp env/prod.db.app.env.example     env/prod.db.app.env
cp env/prod.db.relay.env.example   env/prod.db.relay.env
cp env/prod.db.migrate.env.example env/prod.db.migrate.env

$EDITOR env/prod.env                 # POSTGRES_PASSWORD, CLERK_*, STRIPE_*, PUBLIC_HOSTNAME
$EDITOR env/prod.db.migrate.env      # schema owner + the three role passwords
$EDITOR env/prod.db.app.env          # mytheus_app, with the password set above
$EDITOR env/prod.db.relay.env        # mytheus_relay, with the password set above

# Use the SAME password for a role in every file that names it. bootstrap_roles sets what
# prod.db.migrate.env says; web and relay authenticate with what their own file says, so a
# mismatch shows up as an authentication failure at startup rather than anything subtler.

# 4. Nothing to open. This stack publishes no ports; the existing Caddy on 80/443 proxies to
#    web:8000 over the docker network, and `cf-origin-lock` already restricts 80/443 to
#    Cloudflare ranges. Postgres/Redis/Redpanda stay on the internal compose network.
#    Attach that Caddy to this stack's network if it is not already:
#      docker network connect mytheus_default <caddy-container>

# 5. Deploy
cd deploy && ./deploy.sh
```

## Clerk JWT template (required before the AI tier works)

`mytheus-intelligence` authorizes every request from an `internal_org_id` claim carrying the
resolved internal `org_id` (a UUID), never Clerk's opaque `org_...` id. It reads a claim rather
than joining `public.organizations` deliberately: that table belongs to `mytheus-backend`'s
bounded context.

`identity-tenant-service` publishes the value into the organization's `public_metadata` at
provisioning time (`libs/shared/clerk_admin.py`). Clerk does **not** put `public_metadata` into
session tokens on its own, so one dashboard step is still required:

1. Clerk dashboard -> Sessions -> Customize session token.
2. Add a claim: `"internal_org_id": "{{org.public_metadata.internal_org_id}}"`.

Without it the claim is absent from every token and the AI tier fails closed with 401 on every
request, while the backend keeps working, so the symptom looks like an AI-tier outage rather
than a configuration gap. `CLERK_SECRET_KEY` in `env/prod.env` must also be a real key; with a
placeholder the publish is a logged no-op and the metadata is never written.

Verify a provisioned tenant end to end:

```bash
# the metadata was published
curl -s -H "Authorization: Bearer $CLERK_SECRET_KEY" \
  https://api.clerk.com/v1/organizations/<clerk_org_id> | jq .public_metadata
# and the tenant is resolvable, which is what clerk_org_id exists for
psql -c "SELECT id, clerk_org_id FROM organizations WHERE clerk_org_id IS NOT NULL;"
```

## Verify

```bash
docker compose -f compose.prod.yml ps                       # all services healthy
curl -fsS https://$PUBLIC_HOSTNAME/healthz                   # -> {"status":"ok","service":"core-api"}
docker compose -f compose.prod.yml logs -f relay workflow    # workers running
```

## Notes

- **Migrations** run as a one-shot `migrate` service that `web` waits on
  (`service_completed_successfully`), so the schema is always applied before the app serves
  traffic. It runs two steps: `alembic upgrade head`, then `python -m scripts.bootstrap_roles`.
  The second is not optional. Migration `a1c4e7f20b18` creates `mytheus_app`,
  `mytheus_relay` and `mytheus_admin` with no password (a password in a migration is a
  password in git history), so until bootstrap_roles has run, no application process can
  authenticate at all.
- **Database roles.** `web` and `workflow` connect as `mytheus_app`, `relay` as
  `mytheus_relay`, and only `migrate` holds the schema-owner credential. None of the three
  holds `rolsuper` or `rolbypassrls`, which is what makes every `tenant_isolation` policy
  actually apply; bootstrap_roles re-checks it and refuses to finish if it is ever untrue.
- **Per-store split** is a deploy-time choice (see `../env/README.md`): Postgres can stay
  self-hosted or move to managed Supabase. Note that a managed provider must still be given
  the three roles, so point `BOOTSTRAP_DATABASE_URL` at its owner credential and let the
  `migrate` step create them there too.
- **Realtime / intelligence tiers** are now defined in `compose.prod.yml` behind profiles; see
  "Optional tiers" below.
- **Rollback**: every CI build is tagged with its commit SHA, so pin the previous one and bring
  the stack back up:
  ```bash
  BACKEND_IMAGE=ghcr.io/mytheus-ai/mytheus-backend:<previous-sha> \
    docker compose -f compose.prod.yml up -d
  ```
  `main` is a moving pointer and is therefore never a rollback target. A Hostinger VPS snapshot
  taken before the deploy remains the fallback for anything a re-pin cannot undo (a migration
  that already ran, for instance — those are forward-only).
- **Deploying via Dokploy** is the normal path; this script is the fallback for when Dokploy
  itself is broken. Both run the same compose file under the same project name, `mytheus`, so
  they share one set of containers and one set of volumes rather than creating a second stack.

## Optional tiers (compose profiles)

Off by default so the forced-command `up -d --pull always` cannot fail on an image that is not
published yet. Enable with `COMPOSE_PROFILES=intelligence,realtime,observability` in the deploy
environment. `ner` and `kg` are separate profiles (disabled unless named).

| Profile | Services | Internal ports |
| --- | --- | --- |
| `intelligence` | qdrant, embedding-service(+worker, relay), reranker-service, ingestion-service(+worker), search-service(+worker) | embedding 8101, reranker 8102, ingestion 8103, search 8104 |
| `ner` / `kg` | ner-service / knowledge-graph-service | 8105 / 8106 |
| `realtime` | realtime-gateway, transcription-service | 8090 / 8091 |
| `observability` | prometheus, grafana | 9090 / 3000 (internal only) |

- **Backend consumers + audio tap (default profile, no published ports, METRICS_PORT=9100 scraped by the
  Prometheus `workers` job):** `core-api-consumer`, `meeting-consumer`, `audio-tap-worker`. Each has its own
  env file layered on `prod.env`: `prod.db.core-consumer.env`, `prod.db.meeting-consumer.env` (each its own
  `DATABASE_URL`) and `prod.audio-tap.env` (`INTERNAL_AUDIO_TOKEN`, no DB; must match transcription-service).
  `meeting-service` runs with `AUDIO_TAP_MODE=worker` so the API process never taps audio; the dedicated worker
  connects to `ws://transcription-service:8091/internal/audio` (enable the `realtime` profile too).
  Alert `AudioTapWorkerDown` fires if no audio-tap-worker target is up for 2m.
- **Monthly partitions (operator task, no cron installed):** each month run `scripts/ensure_partitions.py`
  from BOTH mytheus-backend and transcription-service (their partitioned tables stop accepting inserts
  once the next month's partition is missing).
- **Public routes** (Caddy): only the existing gateway, plus `/socket.io/*` on `api.mytheus.cloud` to
  `mytheus-realtime:8090`. Everything else, including Qdrant, transcription and Grafana, is
  internal. A basic-auth Grafana block is in `caddy/mytheus.caddy`, commented out.
- **Qdrant keys**: write key only in `env/prod.embedding.env`; read-only key in `env/prod.search.env`.
- **Object storage**: Cloudflare R2 (ADR-0023), no MinIO. `S3_*` in `prod.platform.env`/`prod.ingestion.env`
  (the intelligence code reads `S3_*` first and falls back to `MINIO_*` only for local MinIO).
- **GPU**: `docker compose -f compose.prod.yml -f compose.gpu.yml --profile intelligence up -d`.
- Validate: `POSTGRES_PASSWORD=x PUBLIC_HOSTNAME=:80 docker compose -f compose.prod.yml --profile '*' config -q`.
- Prometheus/Grafana read `../observability`; if the deploy tool (Dokploy) does not preserve the repo
  layout, set `MYTHEUS_OBS_DIR` to a host path valid in BOTH namespaces (same trap as `MYTHEUS_ENV_DIR`).

## Deploy script versioning (gap 26)

`mytheus-deploy.sh` here is a **reconstruction** of the script on the VPS, written from the CI
invocation and the docs without access to the live file. Before adopting it: diff the VPS copy
against it, reconcile the `ASSUMED` values, then install it (or have the forced command exec the
checked-out copy). Until then the VPS copy remains the one that actually runs.

## TODO-for-owner: VPS host discrepancy (NOT resolved here)

Two different hosts are recorded; confirm which is real and fix the other:

| Host | Where recorded |
| --- | --- |
| `srv1804132` / `187.127.190.246` | `deploy/compose.prod.yml` header (line 5), this file, `mytheus-docs/work-done-till-now/06-frontend-and-ui.md:82` |
| `srv1756037.hstgr.cloud` / `93.127.172.17` (Ubuntu 24.04, KVM 8: 8 vCPU / 32 GB / 400 GB) | `PREVIOUS.md:13`; `env/prod.env.example` (`PUBLIC_HOSTNAME=srv1756037.hstgr.cloud`) |

`VPS_HOST` in the GitHub `production` environment is the live truth and is not visible from the repo.
