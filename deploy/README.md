# deploy/ — VPS deploy (modular monolith)

MVP deploy target: the `mytheus-backend` modular monolith + its data stores, self-hosted on the
existing VPS with Docker Compose. **No Kubernetes, no Terraform** in this band (those are post-W36,
Plan 14). The service seams are real; this co-locates them in one deployable.

## Target

- VPS `srv1756037.hstgr.cloud` (`93.127.172.17`), Ubuntu 24.04, KVM 8 (8 vCPU / 32 GB / 400 GB).
- One backend image runs three roles: `web` (uvicorn), `relay` (outbox drain, the only sanctioned
  producer), `workflow` (Temporal workers).
- Self-hosted `postgres`, `redis`, `redpanda` (Kafka API + Schema Registry), `temporal`, and a
  `caddy` reverse proxy doing automatic HTTPS.

## Files

| File | Purpose |
| --- | --- |
| `compose.prod.yml` | the full stack (stores + backend roles + Caddy) |
| `Caddyfile` | TLS termination + reverse proxy to `web:8000` |
| `deploy.sh` | idempotent bring-up: pull, build, up, wait for health |

## First-time setup on the VPS

```bash
# 1. Install Docker Engine + compose plugin (Ubuntu 24.04)
curl -fsSL https://get.docker.com | sh

# 2. Clone both repos side by side
mkdir -p ~/mytheus && cd ~/mytheus
git clone <mytheus-platform-url> mytheus-platform
git clone <mytheus-backend-url>  mytheus-backend

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

# 4. Open the firewall for HTTP/HTTPS (via the Hostinger firewall or ufw)
#    Only 80/443 need to be public; Postgres/Redis/Redpanda stay on the internal compose network.

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
- **Rollback**: `docker compose -f compose.prod.yml up -d` with the previous image tag, or restore
  a Hostinger VPS snapshot taken before the deploy.
