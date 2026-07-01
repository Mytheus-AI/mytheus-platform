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
