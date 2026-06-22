# CLAUDE.md — Working guide for AI agents in `reprise-platform`

This is the **platform & infrastructure** repo for **Reprise AI** (internal codename **NEXUS**): Terraform IaC, Kubernetes manifests/Helm charts, GitHub Actions CI/CD, the observability stack, secrets wiring, autoscaling, and multi-region DR. It contains **no application code** — it is the substrate that deploys the other Reprise AI repos at scale (5M users, 2M MAU, 20k peak concurrent meetings, 100k peak concurrent participants). Your job here is to change *how and where* services run, never *what* they do.

## Tooling & layout

- **IaC:** Terraform (remote state in Terraform Cloud, plan-on-PR, apply-on-merge with approval). Modules in `terraform/modules/`, per-env stacks in `terraform/environments/{dev,staging,prod}/` (prod is per-region: `prod/us`, `prod/eu`, `prod/ap`).
- **Kubernetes:** `helm/` umbrella chart (one subchart/service, `values-{env}.yaml`) and `k8s/{base,overlays}/` Kustomize. Namespaces map to scaling families: `prod-crud`, `prod-realtime`, `prod-ai`, `prod-async`, `prod-cell-{slug}`, plus cluster-wide `platform`.
- **CI/CD:** `.github/workflows/` — lint/test/scan → build → publish → GitOps commit → Argo Rollouts canary.
- **Observability:** `observability/` — OTel Collector, Prometheus rules, Grafana dashboards, alert routing.
- **Runbooks:** `runbooks/` — on-call, failover, rollback, game-day.
- Read `system.md` for the full picture; cite the canon docs (`16-deployment-and-infrastructure.md`, `14`, `15`, `13`, `17`, `12`) when reasoning about *why*.

## Cross-cutting rules (non-negotiable)

1. **Infrastructure as code only — no click-ops.** Every cloud-substrate change is a Terraform change. Every workload change is a Helm/Kustomize change delivered via GitOps. Nothing is done by hand in a console or with ad-hoc `kubectl apply`.
2. **Secrets are never committed.** No secret in git, in an image, or as a plaintext env var in a manifest. Secrets flow through External Secrets Operator from cloud Secrets Manager, rooted in cloud KMS. Manifests reference an `ExternalSecret`, never a value.
3. **Every change goes through plan → review → apply.** `terraform plan` on PR, `apply` only from Terraform Cloud after review. Workloads merge → GitOps commit → Argo CD reconcile. No shortcut around the gate.
4. **Tenant isolation (`org_id`) must be preserved in any networking or storage change.** Do not weaken RLS, the per-tenant Qdrant `org_id` payload filter, tenant-partitioned Redpanda topics, the `nexus:{org_id}:` Redis prefix, per-tenant KMS data keys, or default-deny `NetworkPolicy`. Cell isolation (dedicated node pools/namespaces) must remain intact.
5. **Each scaling family gets its own autoscaler signal.** CRUD → HPA on req/s; real-time → KEDA on concurrent connections; AI/inference → KEDA + Ray Serve on queue depth/GPU/tokens; async → KEDA on Temporal queue depth. Never collapse two families onto one signal or one node pool (the GPU/AI tier is an independent cost center).
6. **Multi-region / DR invariants hold.** Postgres is the system of record (Qdrant/AGE derived, Redis ephemeral, Redpanda replayable). Per-store replication and per-tier RTO/RPO budgets must not be exceeded. The real-time tier is intentionally not warm in passive — do not "fix" that. Data residency pins tenant compute + data to its region.

## Naming authority

Service names, topic names, store names, bucket names, Redis namespaces, and the `nexus:{org_id}:` prefix are **frozen in `reprise-docs` `_canon/`** (`01-service-catalog.md`, `02-data-model.md`, `03-event-taxonomy.md`). Deploy everything under those **exact** names. Never introduce an alternative name, rename a service in a manifest, or invent a topic/bucket. If a name seems wrong, the fix is in `_canon/` first (via ADR), then it propagates here — never the reverse.

## Do / Don't

**Do**

- Keep a service identical across environments by *values only* (replica floors, resources, thresholds, image digest), never by template.
- Promote images by **digest** (build once at merge); change only `image.digest` per environment.
- Use expand → deploy → contract for any DB migration gating (two app versions run against one DB during rollout).
- Keep the real-time node pool **on-demand, never spot**.
- Scope `ResourceQuota`/`LimitRange`/`NetworkPolicy` per family namespace.

**Don't**

- Never weaken RLS, network isolation, or `org_id` enforcement.
- Never put secrets in manifests, values files, or images.
- Never `kubectl apply` to a cluster directly — go through GitOps.
- Never run `terraform apply` from a laptop.
- Never double the GPU fleet for a blue-green swap — AI/GPU rolls out canary.
- Never re-decide the locked internal transport (gRPC for AI/real-time, REST for `bff`/CRUD) — the optional mesh carries it, it does not replace it.

## How to plan / apply / test

```bash
# Terraform (cloud substrate)
cd terraform/environments/<env>/<region>
terraform fmt -check && terraform validate && tflint
terraform plan                 # on PR; apply runs from Terraform Cloud after review

# Kubernetes workloads (validate locally; never apply by hand)
helm template nexus ./helm -f helm/values-<env>.yaml | kubeconform -strict
kustomize build k8s/overlays/<env> | kubeconform -strict   # or kubeval

# Policy checks
conftest test k8s/overlays/<env>          # OPA/conftest policy gates
tfsec terraform/ && checkov -d terraform/  # IaC security scan
```

## Environment & approval conventions

- **dev** — ephemeral PR preview namespaces (`dev-{family}`, TTL-reaped); dummy/sandbox keys; recreate rollout.
- **staging** — deploys **on merge to `main`**; sandbox keys; same rollout strategy as prod (rehearsal); a smoke + load gate guards promotion.
- **prod** — per-region (`us`/`eu`/`ap`); deploys only after **manual approval** following the staging gate; live keys via ESO + KMS; family-aware rollout.
- Terraform `apply` and any prod deploy require review/approval. Risky changes are blocked when the tier's error budget is burned.

## PR conventions

- **Conventional commits**, **trunk-based** (short-lived branches, frequent merge to `main`).
- Scope a PR to one concern; Terraform changes trigger `plan` + IaC scan, manifest changes trigger render + `kubeconform` + conftest.
- An infra change that touches networking or storage must state explicitly how `org_id`/tenant isolation is preserved.
- **Commits in this project must NOT include a `Co-Authored-By` footer.**
