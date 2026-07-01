# PREVIOUS.md

Running log of what was built here and why, so any human or agent can pick up cleanly.

## Session 1 — Plan 0, Phase 0F (CI + VPS deploy) and Phase 0G (cross-repo conventions)

Executed **Phase 0F** and the platform side of **Phase 0G** of
`mytheus-docs/plan/plan-0-scaffold-and-contracts.md`.

### Key adaptation: self-host on VPS (not Railway/Render)

The resolved infra decision is **self-host on the existing Hostinger VPS**
(`srv1756037.hstgr.cloud` / `93.127.172.17`, Ubuntu 24.04, KVM 8 = 8 vCPU / 32 GB / 400 GB). So
Phase 0F's deploy target was rewritten from the plan's `render.yaml`/`railway.json` to a
**Docker-Compose deploy of the modular monolith + self-hosted Postgres/Redis/Redpanda** on the box.
Everything else in 0F (the CI gates, the multi-stage Dockerfile, the authz check, env management)
is unchanged in spirit. Kubernetes/Terraform remain out of scope (post-W36, Plan 14).

### Phase 0F — what exists now

- **`.github/workflows/ci.yml`** — the canonical CI template: `python` gates (uv sync → ruff +
  black → mypy → pytest), `authz-check` (backend), `avro-compat` (events only, BACKWARD gate
  against a Redpanda Schema Registry service), `security` (gitleaks + pip-audit), `docker` (build
  the backend image). Jobs self-select by repo via `if: contains(github.repository, ...)`.
  `actionlint`-clean. `mytheus-ui` is intentionally out of scope (it owns its own Next.js CI).
- **`scripts/check_authz.py`** — shift-left authz gate: AST-walks `services/**` and fails if any
  FastAPI route has no declared auth and is not explicitly public. Recognizes router-level
  `dependencies=[Depends(...)]`, decorator-level `dependencies=`, per-param `Depends/Security`, a
  PUBLIC path allowlist (health/webhooks/oauth), and a `# authz: public` marker. A runnable copy
  ships in `mytheus-backend/scripts/` (where its CI runs); this is the reference copy.
- **`deploy/compose.prod.yml`** — the VPS stack: self-hosted `postgres`, `redis`, `redpanda`
  (Kafka + Schema Registry), `temporal`; the backend image running three roles (`web` = uvicorn
  core-api, `relay` = outbox drain, `workflow` = Temporal worker) sharing one image; a one-shot
  `migrate` service (`alembic upgrade head`) that `web` waits on; and a `caddy` reverse proxy doing
  automatic HTTPS. `docker compose config` validates; 9 services resolve.
- **`deploy/Caddyfile`**, **`deploy/deploy.sh`** (idempotent bring-up), **`deploy/README.md`**
  (first-time VPS runbook).
- **`env/{dev,staging,prod}.env.example`** + **`env/README.md`** — one template per environment;
  only `.example` files are committed (`.gitignore` blocks filled `env/*.env`). Documents the
  **per-store split**: `DATABASE_URL` chooses self-hosted Postgres vs managed Supabase by changing
  only that one line.
- **`mytheus-backend/Dockerfile`** + **`.dockerignore`** — multi-stage (uv builder resolves wheels
  from the lockfile; slim `python:3.12-slim` runtime; non-root `appuser` uid 10001; `tini` PID 1).
  One image, role selected by the compose `command:`.

### Phase 0F — verification (local)

- `mytheus-backend` image **built** (`mytheus-backend:plan0`) and **booted**: `docker run` → the
  web process answered `/healthz` with `200 {"status":"ok","service":"core-api"}`, running as
  non-root `appuser`. (`/healthz` needs no live backing services, so this validates the image/boot
  path without the full stack.)
- `actionlint .github/workflows/ci.yml` clean; `docker compose -f deploy/compose.prod.yml config`
  valid; `check_authz.py` passes on the current backend routes (and correctly flagged the SCIM stub
  routes until they were guarded with a router-level `Depends(verify_token)`).

**Not done (deliberate checkpoint):** the actual live deploy to the production VPS. Per the infra
decision this is a "confirm per-store split at deploy time" gate; the artifacts + runbook are ready
but pushing to the running box is an outward-facing, hard-to-reverse action awaiting explicit go.

### Phase 0G — cross-repo conventions

- **Uniform `make` targets** (`install`, `lint`, `typecheck`, `test`, `ci = lint typecheck test`)
  now exist in every code repo: `mytheus-backend`, `mytheus-events`, `mytheus-intelligence`,
  `mytheus-platform`, and a new repo-level `mytheus-realtime/Makefile` that delegates to both its
  Node (`tsc` + build) and Python (ruff/black/mypy/pytest) services. `mytheus-realtime` `make ci`
  is green end-to-end.
- **`.pre-commit-config.yaml`** in all five code repos: local ruff/black/mypy hooks (using each
  repo's pinned tools) + gitleaks; events adds a `make validate` (.avsc invariants) hook; backend
  adds the authz-check hook; realtime scopes Python hooks to transcription-service + a gateway
  `tsc` hook; platform runs gitleaks + actionlint.
- **`CONTRIBUTING.md`** in all five code repos, each stating: (1) names come from
  `mytheus-docs/_canon/` — never invent, rename via Glossary + ADR first; (2) **every PR includes
  an `org_id` authz review**; (3) Conventional Commits, trunk-based, **no `Co-Authored-By` footer**;
  (4) the repo's CI gate + `pre-commit install`.
- **Canon-location decision recorded** (in every CONTRIBUTING): canon authority lives in
  `mytheus-docs`; for MVP the contract-binding repos consume it as a **sibling checkout** (clone all
  repos under one parent dir), revisit git-submodule/vendoring post-W36.

`mytheus-ui` was deliberately excluded from 0E/0F/0G (active work ongoing there).
