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

# 3. Fill secrets (never committed)
cd mytheus-platform
cp env/prod.env.example env/prod.env
$EDITOR env/prod.env          # set POSTGRES_PASSWORD, DATABASE_URL, CLERK_*, STRIPE_*, PUBLIC_HOSTNAME

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

- **Migrations** run as a one-shot `migrate` service (`alembic upgrade head`) that `web` waits on
  (`service_completed_successfully`) — schema is always applied before the app serves traffic.
- **Per-store split** is a deploy-time choice in `env/prod.env` (see `../env/README.md`): Postgres
  can stay self-hosted or move to managed Supabase by changing only `DATABASE_URL`.
- **Realtime / intelligence tiers** deploy as their own compose stacks/images (separate scaling
  families, separate cost centers); their deploy descriptors land alongside their scale-out bands.
- **Rollback**: `docker compose -f compose.prod.yml up -d` with the previous image tag, or restore
  a Hostinger VPS snapshot taken before the deploy.
