# env/ — environment configuration

One `*.env.example` template per environment. **Only the `.example` files are committed.** The
filled `dev.env` / `staging.env` / `prod.env` hold secrets and are git-ignored; the `security` CI
job (gitleaks) fails the build if a real secret is ever committed.

| File | Used by |
| --- | --- |
| `dev.env.example` | local dev against the `mytheus-backend` docker-compose stack (localhost ports) |
| `staging.env.example` | staging VPS deploy (`deploy/compose.prod.yml`) |
| `prod.env.example` | production VPS deploy (`deploy/compose.prod.yml`) |

## How secrets flow

For the current stage secrets live in the git-ignored `env/<stage>.env` file on the VPS, read by
`docker compose` at bring-up. There is no secret in the repo, in an image, or in a log. When this
graduates to Kubernetes (post-W36, Plan 14), secrets move to External Secrets Operator + KMS; the
key names here stay the same so the migration is mechanical.

## Per-store split (confirm at deploy time)

`DATABASE_URL` decides where Postgres lives. Default self-hosts it as the compose `postgres`
service. To use a managed Supabase Postgres instead, set `DATABASE_URL` to the Supabase pooled
(port 6543) connection string and remove the `postgres` service from `deploy/compose.prod.yml`.
Redis and Redpanda are self-hosted the same way; each can independently move to a managed provider
by changing only its URL here.

## Store authentication (Redis and Redpanda)

Redis and Redpanda trusted anything on the Docker network until `scripts/enable-store-auth.sh`
(run on the VPS; see its header). It generates every password on the server and writes:

| File | Read by | Keys |
| --- | --- | --- |
| `prod.store-auth.secrets` | nothing (the script's own record) | one password per principal, the Redis password |
| `prod.redis.env` | `redis` | `REDIS_PASSWORD` |
| `prod.redpanda.env` | `redpanda` | `REDPANDA_SASL=1`, `RPK_USER` / `RPK_PASS` / `RPK_SASL_MECHANISM` (admin) |
| `prod.env` | every backend service | `REDIS_URL` with the password, `KAFKA_SASL_USERNAME=backend`, `KAFKA_SASL_PASSWORD` |
| `prod.store.intelligence.env` | every intelligence and graph service | the same, principal `intelligence` |
| `prod.store.realtime.env` | `realtime-gateway`, `transcription-service` | the same, principal `realtime` |

The clients read `KAFKA_SASL_*` through `kafka_auth` (Python) / `kafkaAuth` (gateway); the Schema
Registry login defaults to the same principal. ACLs: every principal may use every topic and group,
but only `backend` may write `decisions` and `actions` (core-api is their only producer). With
none of these files present, both stores start open exactly as before, so the compose change can
deploy ahead of the script. `enable-store-auth.sh check` re-verifies; `rollback` undoes it.
