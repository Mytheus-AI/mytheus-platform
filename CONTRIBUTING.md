# Contributing to mytheus-platform

## Naming comes from canon — never invent
Service, topic, store, and bucket names are frozen in `mytheus-docs/_canon/` and published in
`24-glossary-and-naming.md`. Deploy everything under those exact names — never rename a service in
a manifest or invent a topic/bucket. A rename goes **Glossary + ADR first** in `mytheus-docs`, then
propagates here — never the reverse.

**Canon location (recorded decision):** canon authority lives in `mytheus-docs`. For MVP the
contract-binding repos consume it as a **sibling checkout** — clone all Mytheus repos under one
parent directory. Revisit git-submodule / vendoring post-W36.

## Infra invariants
Infra-as-code only — no console/click-ops. Secrets NEVER committed (gitleaks fails the PR); the
filled `env/*.env` files are git-ignored and live only on the deploy host. Never weaken tenant
isolation (RLS, `org_id`, `nexus:{org_id}:` prefix, default-deny networking) to "make it work".

## Every PR includes an `org_id` authz review
Any change touching networking, storage, or a query path must state how `org_id` / tenant isolation
is preserved. The `scripts/check_authz.py` reference gate asserts every FastAPI route declares auth.
Shift-left security from day one (`11-security-architecture.md` §3.2).

## Standards
- **Conventional Commits**; **no `Co-Authored-By` footer** (per this repo's CLAUDE.md).
- **Trunk-based**: short-lived branches, frequent PRs, mandatory review.
- CI green before merge: `make ci` (actionlint + `compose.prod.yml` config validation) and the
  security job (gitleaks + pip-audit). Install hooks once: `pre-commit install`.
- Current stage ships the VPS Docker-Compose deploy only — no Kubernetes/Terraform (post-W36).
