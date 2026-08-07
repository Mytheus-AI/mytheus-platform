# deploy/ — VPS deploy (modular monolith)

MVP deploy target: the `mytheus-backend` modular monolith + its data stores, self-hosted on the
existing VPS with Docker Compose. **No Kubernetes, no Terraform** in this band (those are post-W36,
Plan 14). The service seams are real; this co-locates them in one deployable.

## Target

- VPS `srv1804132` (`187.127.190.246`), Ubuntu, x86_64.
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
- **Realtime / intelligence tiers** deploy as their own compose stacks/images (separate scaling
  families, separate cost centers); their deploy descriptors land alongside their scale-out bands.
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
