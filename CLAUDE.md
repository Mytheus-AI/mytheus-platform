# CLAUDE.md

This is `mytheus-platform`, the deploy-substrate repo for Mytheus. **What exists today is Docker Compose on one VPS plus GitHub Actions CI**: `deploy/compose.prod.yml` (+ `compose.gpu.yml`), `deploy/deploy.sh`, `deploy/mytheus-deploy.sh` (reviewed copy of the VPS forced command), `deploy/caddy/`, `env/*.env.example`, `observability/` (Prometheus + Grafana), and `.github/workflows/`. It contains no application code; it deploys the other Mytheus repos. Standing rules: never weaken tenant isolation, never commit a secret.

> **Reality check (read before trusting the rest of this file).** There is NO `terraform/`, `k8s/` or `helm/` directory, no Argo CD, no Terraform Cloud state, no EKS/GKE, and nothing is provisioned by IaC. Everything below that mentions Terraform layers, Kubernetes, Helm, Kustomize, Argo CD/Rollouts, multi-region DR or "plan -> review -> apply" describes the **planned post-W36 target (Plan 14), not the repo**; the "Where things live" tree, "Add a Terraform module" and similar recipes are aspirational and their commands cannot be run. The actual deploy path is: CI SSHes to the VPS, a forced command (`/usr/local/sbin/mytheus-deploy.sh`) runs `docker compose up` against `deploy/compose.prod.yml`. The managed-plane table below is likewise target state: today Postgres, Redis, Redpanda, Temporal and Qdrant are self-hosted in compose, and object storage is Cloudflare R2 (ADR-0023).

## Repo at a glance

This repo decides how and where every Mytheus service runs, never what it does. It deploys the full canonical service set (roughly 20 services across four scaling families):

- CRUD / control plane: `api-gateway`, `bff`, `identity-tenant-service`, `core-api`, `meeting-service`, `integration-service`, `billing-metering-service`, `admin-ops-service`, `notification-service`
- Real-time: `realtime-gateway`, `transcription-service`
- AI / inference: `ingestion-service`, `embedding-service`, `reranker-service`, `agent-runtime-service`, `rag-service`, `knowledge-graph-service`, `search-service`
- Async / orchestration: `workflow-service` (Temporal workers)

Two substrates exist, by stage:

- Production substrate (TARGET, not built): Kubernetes on AWS EKS / GCP GKE, provisioned by Terraform (state in Terraform Cloud), workloads delivered by Helm + Kustomize through Argo CD GitOps. Multi-region, active-passive evolving to active-active.
- Early-stage path (ACTUAL): Mytheus runs as a modular monolith on a self-hosted VPS (ADR-0016; Railway/Render was superseded) with Docker Compose as the local-dev source of truth. The service seams are real from day one; the early stage just co-locates them in one deployable. Services are then extracted onto K8s in the frozen Wave 1-4 order (below).

Ground every "why" in `system.md` and the canon docs it cites (`16-deployment-and-infrastructure.md` is the key one; also `15-observability-and-sre.md`, `14-reliability-and-dr.md`, `13-scalability-and-performance.md`, `17-cost-and-finops.md`, `12-compliance-and-privacy.md`).

## Architecture orientation

Service boundaries are cut along scaling families so each family gets one independent autoscaler signal and its own cost center. A Kubernetes namespace boundary equals a scaling-family boundary equals an autoscaler-signal boundary; `ResourceQuota`, `LimitRange`, and `NetworkPolicy` are scoped per family.

The four families and how each deploys and autoscales:

| Family | Namespace | Autoscaler signal | Autoscaler | Rollout style |
|---|---|---|---|---|
| CRUD / control plane | `prod-crud` | HTTP req/s + p95 latency | HPA (CPU/RPS) | blue-green / rolling |
| Real-time | `prod-realtime` | concurrent WebSocket connections / live audio streams | KEDA (active connections) | connection-drain |
| AI / inference | `prod-ai` | queue depth / chunk backlog, GPU util, token throughput | KEDA + Ray Serve | canary 5 -> 25 -> 50 -> 100 |
| Async / orchestration | `prod-async` | Temporal task-queue depth | KEDA (Temporal scaler) | Temporal Worker Versioning |

Tuning uses the surge budget A10 = 4:1 peak:average: target roughly 50-60% utilization for about 2x burst headroom before scale-out, with the rest of the 4x surge absorbed by replicas added into pre-warmed floors. The real-time node pool is on-demand, never spot (spot reclamation would sever live connections). The GPU/AI tier runs on dedicated GPU node pools and is an independent cost center; it never shares hardware with CRUD.

Extraction waves (Railway/Render -> Kubernetes, strangler-fig, in this exact order; each wave is one scaling family and one ownership boundary):

- Wave 1 - GPU + real-time + workers: `embedding-service`, `reranker-service`, `agent-runtime-service`, `transcription-service`, `realtime-gateway`, `workflow-service` (different runtime/scaling; Railway/Render offers no GPU pools or KEDA-on-connections).
- Wave 2 - CRUD core: `core-api`, `identity-tenant-service` (the relational heart and control plane outgrow the shared deployable under req/s pressure).
- Wave 3 - SaaS business: `billing-metering-service`, `integration-service`, `admin-ops-service` (bursty, monetization-critical; extract once paying tenants land).
- Wave 4 - retrieval stores: `knowledge-graph-service`, `search-service` (start as libraries inside `rag-service`; split last).

Managed planes wired here (this repo provisions and wires them; app repos consume them, no secrets committed):

| Plane | Provider | Wired by (Terraform layer / config) |
|---|---|---|
| Relational store of record | Supabase Postgres (primary + read replica + PITR) | `data` |
| Vector store | Qdrant Cloud (per-tenant collections, `org_id` payload filter) | `data` |
| Cache / pub-sub / queues | Upstash Redis (`nexus:{org_id}:` prefix, ephemeral) | `data` |
| Object storage | **Cloudflare R2** (S3-compatible; `mytheus-recordings`, `mytheus-documents`, `mytheus-audit-archive`, `mytheus-invoices`, `mytheus-exports`, each `{org_id}/` prefixed) | `data` (the bucket is a store, even though Cloudflare's CDN/WAF is `edge`) |
| Event backbone | Redpanda + Schema Registry (BYOC, tenant-partitioned, Avro BACKWARD) | `data` |
| Durable execution | Temporal Cloud namespace | `data` |
| Identity | Clerk (SSO/SAML/SCIM) | `secrets` + service config |
| Meeting transport | LiveKit (SFU behind a transport adapter) | `secrets` + service config |
| Transcription | Deepgram (WS proxy, server-side key) | `secrets` |
| Billing | Stripe | `secrets` |
| LLM routing | LiteLLM fronting Anthropic | `secrets` |

## Where things live

```
mytheus-platform/
├── terraform/
│   ├── modules/                 # versioned, region-reusable modules: network, cluster, data, edge, secrets, observability
│   └── environments/
│       ├── dev/
│       ├── staging/
│       └── prod/{us,eu,ap}/     # one per-region stack per prod region
├── k8s/
│   ├── base/                    # Kustomize bases: NetworkPolicy, ResourceQuota, LimitRange per family
│   └── overlays/                # dev / staging / prod, plus per-region and per-cell overlays
├── helm/                        # nexus umbrella chart (one subchart per service) + values-{env}.yaml
├── .github/workflows/           # lint/test/scan, build, publish, GitOps deploy, rollout
├── observability/               # OTel Collector, Prometheus rules, Grafana dashboards, alert routing
└── runbooks/                    # on-call, failover, rollback, game-day
```

Terraform module purposes:

| Module | Manages |
|---|---|
| `network` | VPC, AZ-spread subnets, NAT, private endpoints, cross-region peering for replication |
| `cluster` | EKS/GKE control plane, the four family node pools + per-cell tainted pools, IRSA / Workload Identity |
| `data` | Supabase refs, managed Postgres (primary + replica + PITR), Qdrant Cloud, Upstash Redis, Redpanda BYOC, Temporal Cloud namespace |
| `edge` | Cloudflare CDN/WAF, DNS, custom domain, geo-routing and health-checked failover |
| `secrets` | Cloud KMS keys (incl. per-tenant KMS data keys for `oauth_tokens`), Secrets Manager entries, IAM roles for External Secrets |
| `observability` | Managed Prometheus/Grafana wiring, Sentry project, log sinks |

Remote state lives in Terraform Cloud, split per `(account, region, layer)` so blast radius is bounded: a botched `prod/eu/data` apply cannot touch `prod/us/cluster`. A new region is a new `region` variable instantiation of the same modules, never a copy-paste.

## Invariants you must not break

| Rule | Why | If you break it |
|---|---|---|
| Infra-as-code only, no console changes | The repo and Terraform state must equal reality; click-ops creates invisible drift no one can review or reproduce | Drift detection flags it; the next apply may revert or clobber your change; outage with no reviewable cause |
| Secrets never committed | A secret in git/image/plaintext manifest is permanently leaked and breaks SOC2 controls | `gitleaks` gate fails the PR (day one); if merged, the credential must be rotated everywhere it is used |
| Every change goes plan -> review -> apply | Review of the plan is the only checkpoint before cloud state changes; `apply` runs from Terraform Cloud, never a laptop | Unreviewed apply can corrupt remote state or take a region down with no approver and no rollback path |
| Preserve `org_id` / tenant isolation | RLS, per-tenant Qdrant collections + `org_id` filter, tenant-partitioned Redpanda topics, `nexus:{org_id}:` Redis prefix, per-tenant KMS data keys, default-deny NetworkPolicy, and per-cell node pools/namespaces are the whole multi-tenant safety model | Cross-tenant data exposure; GDPR/residency violation; security incident |
| Each scaling family keeps its own autoscaler signal and node pool | Families have orthogonal load shapes and cost centers; one signal cannot serve two | Mis-scaling (starved or runaway); GPU cost leaks into CRUD; cost center accounting breaks |
| Multi-region / DR invariants hold | Postgres is system of record (Qdrant/AGE derived, Redis ephemeral, Redpanda replayable); per-tier RPO/RTO budgets are contractual; residency is legal | Data loss beyond RPO, downtime beyond the tier budget, or a residency breach |

DR specifics that are intentional, not bugs: active-passive evolving to active-active; the real-time tier is deliberately not kept warm in passive (on region loss, SDK clients reconnect to the surviving region and the LiveKit room is re-established there; the passive region optimizes for fast resumption of new meetings, not zero-loss in-flight migration). Do not "fix" this. RPO/RTO budgets by tier: Free 99.5% (single-region, pooled + RLS), Pro 99.9% (multi-region active-passive), Enterprise 99.95% (cell isolation, active-active candidate). No RTO may exceed the downtime budget of the tier it serves.

## Naming authority

Service names, topic names, store names, bucket names (`mytheus-recordings`, `mytheus-documents`, `mytheus-audit-archive`, ...), the AGE graph `nexus_knowledge`, and the `nexus:{org_id}:` Redis prefix are frozen in `mytheus-docs` `_canon/` (`01-service-catalog.md`, `02-data-model.md`, `03-event-taxonomy.md`). Deploy everything under those exact names. Never rename a service in a manifest, invent a topic or bucket, or introduce an alias. If a name seems wrong, the fix lands in `_canon/` first via ADR, then propagates here, never the reverse.

## Common tasks (recipes)

Add a Terraform module and wire it per environment:
1. Create `terraform/modules/<name>/` with `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`. Take `region` (and `account`/`environment` where relevant) as variables so the module is region-reusable.
2. Instantiate it in each `terraform/environments/<env>/<region>/` stack that needs it, passing the env/region variables. Do not copy resources between stacks.
3. Run `terraform fmt`, `terraform validate`, `tflint`, and `tfsec`/`checkov` locally.
4. Open a PR. Gate: plan-on-PR runs automatically; `apply` runs from Terraform Cloud after review and approval. Never apply from a laptop.

Add a K8s Deployment/Service plus autoscaler for a service:
1. Confirm the service name in `_canon/01-service-catalog.md` and its scaling family.
2. Add a subchart under the `helm/` umbrella chart; the template must be identical across environments. Encode per-env differences (replica floor, resources, autoscaler thresholds, image digest) only in `values-{env}.yaml`.
3. Place it in the correct family namespace (`prod-crud` / `prod-realtime` / `prod-ai` / `prod-async`, or `prod-cell-{slug}` for a dedicated cell). Add the standard pod labels: `app`, `family`, `version` (git SHA), `tenant-cell` (or `pooled`).
4. Attach the family-correct autoscaler, not a generic one: CRUD -> HPA on req/s + p95; real-time -> KEDA on active connections; AI -> KEDA + Ray Serve on queue depth / GPU / tokens; async -> KEDA on Temporal queue depth.
5. Confirm the default-deny NetworkPolicy still admits only the intended callers (only `api-gateway` ingresses `prod-crud`; only the bus and authorized internal callers reach `prod-ai` / `prod-realtime`).
6. Validate with `helm template ... | kubeconform -strict` and `conftest test`. Gate: render + kubeconform + conftest on PR; delivery is a GitOps `image.digest` bump reconciled by Argo CD, never `kubectl apply`.

Add a GitHub Actions deploy workflow with migration gating:
1. Add the workflow under `.github/workflows/`. Stages: lint/test/scan -> build once at merge (tag by git SHA, pin by digest, push to regional ECR/GAR) -> promote by digest (same image staging -> prod; change only Helm `image.digest`, never rebuild) -> GitOps commit -> Argo Rollouts canary with SLO analysis steps.
2. Use the family-aware rollout strategy from the table above; let Argo Rollouts auto-revert the digest commit on SLO regression.
3. Migration gating: because canary/blue-green run two app versions against one database, Alembic migrations must be expand -> deploy -> contract (additive first; destructive only after 100% is on the new version). This is the relational mirror of the Avro BACKWARD rule for events. Gate: staging deploys on merge; prod requires manual approval after the staging smoke + load gate.

Add an observability dashboard or alert:
1. Add Prometheus rules / Grafana dashboards under `observability/`. Every series, log line, and span must carry `org_id` (tenant-attributable). Pick the right family profile: CRUD req/s + p95; real-time concurrent connections; AI GPU util + token throughput + chunk backlog; async task-queue depth.
2. Common alert classes: SLO breach, consumer-lag (embedding lag < 5s, alert at 30s), DLQ rate (< 0.1%), GPU saturation, per-tenant token-budget/quota, and cost (LLM spend is ~94% of variable cost; LLM cost per tenant per day is an error-budgeted signal). Route to PagerDuty with family-aware escalation.

Add a secret (via the secrets manager, not the repo):
1. Create the secret in the cloud Secrets Manager (AWS/GCP), rooted in cloud KMS; add the entry and IAM role in the Terraform `secrets` layer.
2. Reference it from the workload with an `ExternalSecret` (External Secrets Operator reconciles it). Manifests reference the `ExternalSecret`, never the value. Scope each credential to the owning service only.
3. Per-environment scoping: dev dummy/sandbox keys, staging sandbox keys (Stripe test mode, Deepgram dev), prod live keys via ESO + KMS. Never put the value in git, an image, a values file, or a plaintext env var.

Add a new region to the topology:
1. Create `terraform/environments/prod/<region>/` instantiating the same `network` + `cluster` + `data` + `edge` modules with the new `region` variable. Do not copy-paste another region's resources.
2. Add the matching Kustomize overlay under `k8s/overlays/` and the per-region Helm values.
3. Wire per-store replication (Postgres async replica + PITR, Redpanda MirrorMaker2, object cross-region async replication, Qdrant snapshot-ship or re-derive) and Cloudflare health-checked DNS failover.
4. Confirm data residency: tenant compute and data pin to `data_residency.region`; regional buckets follow `object_bucket_region`. Gate: plan -> review -> apply from Terraform Cloud.

## Testing and validation

Must pass before any apply or merge:

- Terraform: `terraform fmt -check`, `terraform validate`, `tflint`, and `tfsec`/`checkov` on every PR touching `terraform/`; plan-on-PR.
- Workloads: `helm template ... | kubeconform -strict` (or `kubeval`), `kustomize build`, and OPA/`conftest` policy checks.
- Standing security gates (shift-left): `gitleaks` (secret scanning, day one), dependency scanning, image scanning (Trivy/Grype), IaC scanning (`tfsec`/`checkov`), and the authz check asserting `org_id` injection on every new query path.
- Argo Rollouts SLO analysis between canary weights (RAG p95 < 500 ms, agent e2e p95 < 4 s, embedding batch < 100 ms, error rate, saturation) auto-reverts on regression.

## Local development

Prerequisites: `terraform`, `kubectl`, `helm`, `kustomize`, the relevant cloud CLI (`aws` / `gcloud`), and access to Terraform Cloud plus the deployment GitOps repo.

```bash
# Cloud substrate (per env, per region). apply runs from Terraform Cloud, never a laptop.
cd terraform/environments/<env>/<region>
terraform init
terraform fmt -check && terraform validate && tflint
terraform plan

# Workloads (validate only; never apply by hand)
helm template nexus ./helm -f helm/values-<env>.yaml | kubeconform -strict
kustomize build k8s/overlays/<env> | kubeconform -strict

# Policy and security
conftest test k8s/overlays/<env>
tfsec terraform/ && checkov -d terraform/
```

## Pitfalls

- Committing a secret or a populated `*.tfvars` with live values. Use the secrets manager + `ExternalSecret`; keep secret values out of git entirely.
- Click-ops drift: changing anything in a cloud console or via ad-hoc `kubectl apply`. The next apply or Argo reconcile will fight you.
- Weakening a default-deny NetworkPolicy or an RLS / `org_id` assumption to "make it work". This is a tenant-isolation breach, not a fix.
- Coupling two scaling families to one autoscaler signal or one node pool. Each family stays independent; the GPU tier stays its own cost center.
- Applying without a reviewed plan, or applying from a laptop instead of Terraform Cloud.
- Breaking remote state: editing state by hand, crossing the per-`(account, region, layer)` split, or copy-pasting resources between region stacks instead of reinstantiating modules.
- Region / residency mismatch: placing tenant compute or buckets outside `data_residency.region` / `object_bucket_region`.
- Doubling the GPU fleet for a blue-green swap; AI/GPU rolls out canary by design.
- A destructive DB migration that runs before 100% is on the new version (violates expand -> deploy -> contract).

## Working with other repos

This repo deploys, but does not own, the application repos: `mytheus-backend` (`api-gateway`, `bff`, `core-api`, `identity-tenant-service`, `meeting-service`, `billing-metering-service`, `integration-service`, `admin-ops-service`, `notification-service`, `workflow-service`), `mytheus-realtime` (`realtime-gateway`, `transcription-service`), `mytheus-intelligence` (the AI/inference tier), `mytheus-events` (Avro schemas and the topic taxonomy), and the two clients `mytheus-ui` and `mytheus-mobile`. The authoritative repo list is the table in `mytheus-docs/CLAUDE.md`.

## Commit and PR conventions

- Conventional commits; trunk-based development with short-lived branches and frequent merge to `main`.
- Terraform changes: plan-on-PR + IaC scan; apply-on-merge from Terraform Cloud after review and approval.
- Manifest changes: render + `kubeconform` + `conftest` on PR; delivery via GitOps `image.digest` bump (Argo CD), never `kubectl apply`.
- Staging deploys on merge to `main`; prod deploys require manual approval after the staging smoke + load gate. Risky rollouts are blocked when the tier's error budget is burned.
- Scope each PR to one concern. Any PR touching networking or storage must state explicitly how `org_id` / tenant isolation is preserved.
- Commits in this project must NOT include a `Co-Authored-By` footer.
