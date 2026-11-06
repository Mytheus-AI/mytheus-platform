# `mytheus-platform` - Platform & Infrastructure System Doc

Deep reference for the deployment substrate of **Mytheus** (internal codename **NEXUS**). This is the platform-engineering repo: it builds the cloud substrate, packages and schedules every service, ships them through CI/CD, observes them, and keeps them available across regions. It contains no application logic - it deploys the other Mytheus repos.

Canon references throughout cite the architecture set by filename: `16-deployment-and-infrastructure.md` (the key doc), `15-observability-and-sre.md`, `14-reliability-and-dr.md`, `13-scalability-and-performance.md`, `17-cost-and-finops.md`, and `12-compliance-and-privacy.md`. Frozen names (service names, topic names, store names, the `nexus:{org_id}:` Redis prefix) come from `mytheus-docs` `_canon/` and are used verbatim.

---

## 1. Purpose & scope

`mytheus-platform` is the single home for **where every Mytheus service runs, how it is built and shipped, how it is observed, and how the topology grows from the first deploy to multi-region scale**. It owns:

- The cloud substrate (Terraform IaC).
- Kubernetes packaging, scheduling, isolation, and ingress.
- Autoscaling configuration per scaling family.
- The wiring to managed data and service planes.
- CI/CD and progressive delivery.
- Secrets injection.
- The observability stack and SLO dashboards/alerts.
- Multi-region topology, DR, and failover runbooks.

It does **not** rename services (that is `mytheus-docs` `_canon/01-service-catalog.md`), redefine containers (that is `03-container-architecture.md`), or re-derive load (that is `_canon/05-capacity-math.md`). The infra specifics it does introduce - replica floors, HPA targets, node-pool shapes, rollout weights - are derived from, and never contradict, the frozen capacity anchors (A5 = 20k concurrent meetings, A6 = 100k concurrent participants, A10 = 4:1 peak:average, L9 ≈ 8,930 LLM calls/s, EM2 ≈ 525 embeds/s, EM4 ≈ 700 query-embeds/s).

---

## 2. The three scaling families (plus async) and how they deploy

Service boundaries are cut along scaling families precisely so each gets an independent autoscaler signal and its own cost center (`13-scalability-and-performance.md` §3). A Kubernetes namespace boundary equals a scaling-family boundary equals an autoscaler-signal boundary, so `ResourceQuota`, `LimitRange`, and `NetworkPolicy` are scoped per family.

| Family | Namespace | Services | Autoscaler signal | Autoscaler |
|---|---|---|---|---|
| CRUD / control plane | `prod-crud` | `api-gateway`, `bff`, `identity-tenant-service`, `core-api`, `meeting-service`, `integration-service`, `billing-metering-service`, `admin-ops-service`, `notification-service` | HTTP req/s + p95 latency | **HPA** (CPU/RPS) |
| Real-time | `prod-realtime` | `realtime-gateway`, `transcription-service` | Concurrent WebSocket connections / live audio streams (A6 / A5) | **KEDA** (custom metric: active connections) |
| AI / inference | `prod-ai` | `ingestion-service`, `embedding-service`, `reranker-service`, `agent-runtime-service`, `rag-service`, `knowledge-graph-service`, `search-service` | Queue depth / chunk backlog, GPU util, token throughput (L9 / EM2 / EM4) | **KEDA + Ray Serve** autoscale |
| Async / orchestration | `prod-async` | `workflow-service` (Temporal workers) | Temporal task-queue depth | **KEDA** (Temporal scaler) |

Each family runs on a distinct node-pool shape so the GPU cost center never shares hardware with CRUD pods. HPA/KEDA tuning uses A10 = 4:1 as the surge budget; a ~50–60% target utilization gives ~2× burst headroom before scale-out, and the rest of the 4× surge is absorbed by adding replicas into pre-warmed/over-provisioned floors. Replica floors (engineering specifics, not capacity anchors): `api-gateway` 3/region, `realtime-gateway` 6, `transcription-service` 6, `embedding-service` 2 GPU, `reranker-service` 2 GPU, `agent-runtime-service` 4, `core-api` 3, `workflow-service` 2; all others floor at 2 across AZs.

---

## 3. Compute platform

### 3.1 Production: Kubernetes + Terraform

Production runs on **Kubernetes (AWS EKS / GCP GKE) with Terraform IaC**, multi-region active-passive evolving to active-active (`16-deployment-and-infrastructure.md` §2, ADR-0014). Placement composes along three orthogonal axes:

1. **Region** - one cluster per region (`us`, `eu`, `ap`), matching `data_residency.region`. A tenant's compute runs in the region its data is pinned to.
2. **Environment** - a namespace prefix per environment (`dev`, `staging`, `prod`). `dev`/`staging` share a non-prod cluster; `prod` is isolated and per-region.
3. **Cell** - within `prod`, the pooled long tail shares default node pools and namespaces; large/enterprise tenants get a dedicated cell (`prod-cell-{slug}`: node pool + namespace) per `06-multi-tenancy.md` §3.6.

### 3.2 Early stage: Railway/Render modular monolith

Before Kubernetes is warranted, Mytheus runs as a **modular monolith on Railway/Render**, with Docker Compose as the local-dev source of truth (carried over verbatim from the original execution plan). The service seams are real from day one; the early stage simply co-locates them in one deployable.

### 3.3 Extraction waves (Railway/Render → Kubernetes)

Migration peels services off in the **frozen Wave 1–4 order** from `_canon/01-service-catalog.md` §7 using the strangler-fig pattern - never a new sequence. Because each wave is exactly one scaling family and one ownership boundary, no extraction re-cuts a domain seam.

| Wave | Extracted | Why first/last |
|---|---|---|
| **Wave 1** - GPU + real-time + workers | `embedding-service`, `reranker-service`, `agent-runtime-service`, `transcription-service`, `realtime-gateway`, `workflow-service` | Different runtime/scaling from the start; Railway/Render cannot offer GPU pools or KEDA-on-connections |
| **Wave 2** - CRUD core | `core-api`, `identity-tenant-service` | The relational heart and control plane outgrow the shared deployable under req/s pressure |
| **Wave 3** - SaaS business | `billing-metering-service`, `integration-service`, `admin-ops-service` | Bursty, monetization-critical; extract once paying tenants land |
| **Wave 4** - retrieval stores | `knowledge-graph-service`, `search-service` | Start as libraries inside `rag-service`; split last - they share read models with `core-api` |

Extraction mechanics: cut over the bus first (point the extracted service at the same Redpanda topics - at-least-once + idempotency makes a brief dual-run safe, duplicates dedupe on `idempotency_key`), repoint sync calls from in-process to gRPC/REST, run both, drain the monolith's copy, delete the module.

---

## 4. Terraform layout

Terraform Cloud is the single control plane for all cloud-provider state; nothing is click-opped in production. Kubernetes *workloads* are Helm/GitOps (§7); the cloud substrate beneath them is Terraform.

| Layer (module) | Manages |
|---|---|
| `network` | VPC, subnets (AZ-spread), NAT, private endpoints, cross-region peering for replication |
| `cluster` | EKS/GKE control plane, the four family node pools + per-cell tainted pools, IRSA / Workload Identity bindings |
| `data` | Supabase project refs, managed Postgres (primary + read replica + PITR), Qdrant Cloud clusters, Upstash Redis, Redpanda BYOC cluster, Temporal Cloud namespace |
| `edge` | Cloudflare CDN/WAF, DNS, custom domain, geo-routing and health-checked failover policy |
| `secrets` | Cloud KMS keys (incl. **per-tenant KMS data keys** for `oauth_tokens`), Secrets Manager / Parameter Store entries, IAM roles for External Secrets |
| `observability` | Managed Prometheus/Grafana wiring, Sentry project, log sinks |

**State & module conventions:**

- **Remote state** in Terraform Cloud, split per `(account, region, layer)` so a blast radius is bounded - a botched `prod/eu/data` apply cannot touch `prod/us/cluster`.
- **Versioned, region-reusable modules.** A new region is a new `region` variable instantiation of the same `cluster` + `data` + `edge` modules, not a copy-paste.
- **Plan-on-PR, apply-on-merge with approval.** Plans run on every PR touching `terraform/`; `apply` is gated on review and runs from Terraform Cloud, never a laptop.
- **Drift detection.** Terraform Cloud drift detection runs on a schedule; reconciled state is the source of truth.
- The real-time node pool is **on-demand, never spot** - spot reclamation would sever live WebSocket/transcription connections.

---

## 5. Kubernetes

- **Namespaces per tier** (§2): `prod-crud`, `prod-realtime`, `prod-ai`, `prod-async`, `prod-cell-{slug}` per cell tenant, plus a cluster-wide `platform` namespace (External Secrets Operator, KEDA, ingress controller, cert-manager, Prometheus/Grafana, optional mesh control plane). Staging/dev mirror with `staging-{family}` / `dev-{family}`.
- **Packaging: Helm + Kustomize.** A single **Helm umbrella chart** with one subchart template per service and per-environment `values-{env}.yaml` overlays; a service differs across environments only by values (replica floors, resources, autoscaler thresholds, image digest), never by template, so it cannot drift between staging and prod. Kustomize overlays carry environment/region/cell specifics. Every pod carries standard labels - `app`, `family` (`crud`/`realtime`/`ai`/`async`), `version` (git SHA), `tenant-cell` (or `pooled`).
- **Network policies: default-deny per namespace.** Only `api-gateway` may ingress to `prod-crud`; only the bus and authorized internal callers may reach `prod-ai` / `prod-realtime`. This is the network-layer enforcement of the deny-by-default posture (`06-multi-tenancy.md`, `11-security-architecture.md`).
- **Ingress: `api-gateway` behind Cloudflare.** All external traffic enters through **Cloudflare CDN + WAF** and is funneled into the single ingress, `api-gateway`. An ingress controller (NGINX or cloud LB controller) terminates TLS; `api-gateway` performs WAF passthrough, global rate limiting, Clerk JWT pre-validation, and `org_id` extraction before routing to `bff` (UI) or `realtime-gateway` (WebSocket). Nothing reaches an internal service except through `api-gateway` or the Redpanda bus.
- **Service mesh (optional) for gRPC.** A mesh (Linkerd preferred for low overhead; Istio if richer policy is needed) is optional and not locked in canon. If adopted, it *carries* the already-locked internal sync transport - gRPC for AI/real-time tiers, REST for `bff`/CRUD - and adds mTLS between all calls, traffic-shifting primitives for the canary, and uniform retries/timeouts/circuit-breaking on the warm-RAG path (`rag-service` → `reranker-service`/`embedding-service`, <500 ms budget). It is an operability upgrade, never a correctness dependency.

---

## 6. Autoscaling

- **HPA** drives the CRUD/control-plane family on HTTP req/s + p95 latency.
- **KEDA scalers, one signal per family:**
  - Real-time → custom metric on **active WebSocket connections / live audio streams** (toward A6 / A5).
  - AI/inference → **queue depth / chunk backlog**, GPU utilization, and token throughput (toward L9 / EM2 / EM4).
  - Async → **Temporal task-queue depth**.
- **Ray Serve** autoscales the GPU inference deployments (`embedding-service`, `reranker-service`) on GPU utilization and request queue, off the API tier and on dedicated GPU node pools - the cost-center separation is enforced at the node-pool boundary (ADR-0008, `09-rag-and-inference-serving.md`).
- The same KEDA signals that autoscale each family are the signals that gate its rollout (§7) and feed its dashboards (§9).

---

## 7. Managed planes wired here

`mytheus-platform` provisions and wires the managed data and service planes; the application repos consume them. No secrets are committed - connection strings and keys flow through ESO (§8).

| Plane | Provider | Wired by |
|---|---|---|
| Relational store of record | **Supabase Postgres** (primary + read replica + PITR) | `data` Terraform layer |
| Vector store | **Qdrant Cloud** (per-tenant collections, `org_id` payload filter) | `data` layer |
| Cache / pub-sub / queues | **Upstash Redis** (namespaced `nexus:{org_id}:`, ephemeral) | `data` layer |
| Event backbone | **Redpanda + Schema Registry** (BYOC, tenant-partitioned, Avro BACKWARD) | `data` layer |
| Durable execution | **Temporal Cloud** namespace | `data` layer |
| Identity | **Clerk** (SSO/SAML/SCIM) | `secrets` + service config |
| Meeting transport | **LiveKit** (self-hostable SFU behind a transport adapter) | `secrets` + service config |
| Transcription | **Deepgram** (WS proxy, server-side key in `transcription-service`) | `secrets` |
| Billing | **Stripe** (subscriptions/seats/dunning/tax) | `secrets` |
| LLM routing | **LiteLLM** fronting **Anthropic** | `secrets` |

---

## 8. Multi-region & DR

- **Region strategy:** multi-region **active-passive → active-active** (ADR-0009, `14-reliability-and-dr.md`). The three families fail over as units because they share a region and a data plane.
- **Per-store replication:** Postgres async streaming replica (lag < 5s) + PITR; Redpanda mirror (MirrorMaker2); object storage cross-region async replication; Qdrant snapshot-ship or re-derive from Postgres. Postgres is the system of record - Qdrant and the AGE `nexus_knowledge` graph are *derived* (rebuildable), Redis is *ephemeral* (never backed up), Redpanda is a *replayable log*.
- **Real-time is deliberately not kept warm in passive.** Live meetings are stateful sub-2s connections; on region loss, SDK clients reconnect to the surviving region and the LiveKit room is re-established there. The passive region is optimized for fast *resumption of new meetings*, not zero-loss in-flight migration.
- **Availability / RPO / RTO targets** (`14-reliability-and-dr.md` §2, `_canon/05-capacity-math.md` §11.2):

  | Plan tier | Availability | Allowed downtime/mo | Posture |
  |---|---|---|---|
  | Free | 99.5% | ~3h 39m | Single-region, pooled + RLS |
  | Pro | 99.9% | ~43m | Multi-region active-passive |
  | Enterprise | 99.95% | ~22m | Cell-based isolation, active-active candidate |

  No RTO may exceed the downtime budget of the tier it serves.
- **Failover routing:** Cloudflare health-checked DNS swings traffic to the passive region on primary failure. Failover, rollback, and game-day procedures live in `runbooks/`.
- **Data residency per tenant region:** tenant compute + data pinned to `data_residency.region` (`us`/`eu`/`ap`), enforced for GDPR (`12-compliance-and-privacy.md`). Object buckets (`nexus-recordings`, `nexus-documents`, …) are regional per `object_bucket_region`.

---

## 9. CI/CD

GitHub Actions is the CI/CD engine (ADR-0015 stack, `16-deployment-and-infrastructure.md` §5), with **staging deploy on merge** carried over verbatim. App repos build and test their own code; this repo owns the deploy substrate and the rollout policy.

- **Build / test in app repos:** lint/typecheck (`ruff`, `mypy`, `eslint`, `tsc`), tests (Pytest, Vitest), Playwright E2E in a preview namespace, plus standing security gates - secret scanning (`gitleaks`, day one), dependency scanning, image scanning (Trivy/Grype), IaC scanning (`tfsec`/`checkov`), and an **authz check** asserting `org_id` injection on every new query path (reviewed in every PR).
- **Image publish:** built once at merge, tagged by git SHA, pinned by digest, pushed to the regional registry (ECR/GAR).
- **Image promotion by digest:** the *same* image flows staging → prod; promotion changes only the Helm `image.digest` value, never rebuilds - the artifact validated in staging is bit-for-bit the one in prod.
- **GitOps / Argo CD deploy:** the pipeline's "deploy" step is a commit to the deployment GitOps repo (bump `image.digest`), not a direct `kubectl apply`. Argo CD reconciles each cluster against git, so cluster state always equals git, drift is auto-corrected, and a rollback is a git revert.
- **Progressive delivery / canary, family-aware** (§7 of the canon doc): CRUD → blue-green/rolling; AI/GPU → canary 5%→25%→50%→100% (GPUs are too costly to double for blue-green); real-time → connection-drain (new pods accept, old pods finish meetings to completion, then terminate); async → Temporal Worker Versioning (in-flight workflows pin to the build that started them). Argo Rollouts evaluates SLO analysis steps between weights (RAG p95 < 500 ms, agent e2e p95 < 4 s, embedding batch < 100 ms, error rate, saturation) and auto-reverts the digest commit on regression.
- **Migration gating:** blue-green/canary run two app versions against one database, so **Alembic migrations must be expand → deploy → contract** (additive first, destructive only after 100% is on the new version) - the relational mirror of the Avro BACKWARD-compatibility rule for events.

---

## 10. Secrets management

- **Mechanism:** the **External Secrets Operator (ESO)** reconciles from the cloud secret store (AWS Secrets Manager / GCP Secret Manager), with **cloud KMS** as the encryption root. Optionally **Vault** where richer secret workflows are needed. No secret is ever committed to git, baked into an image, or set as a plaintext env var in a manifest - Argo CD references the `ExternalSecret`, never the value.
- **Per-environment scoping:** dev uses dummy/sandbox keys, staging uses sandbox keys (Stripe test mode, Deepgram dev), prod uses live keys via ESO + KMS.
- **Secret classes:** platform service credentials (Clerk, Deepgram, LiteLLM provider keys, Stripe, LiveKit, Qdrant/Redis/Redpanda) scoped to the owning service only; **per-tenant KMS data keys** for `oauth_tokens` envelope encryption, used only by `integration-service`; per-service least-privilege connection strings rotated via the Terraform `secrets` layer.
- The "no secret in git" rule is enforced by the `gitleaks` gate from day one (§9).

---

## 11. Observability stack

The deployment is instrumented with the locked stack (ADR-0015, `15-observability-and-sre.md`) and tied to the SLOs. Pipeline: every service emits via OTel SDK + prom-client + JSON logger →

- **OpenTelemetry Collector** (DaemonSet per node) → **Tempo** (traces) and **Prometheus** (metrics).
- **Prometheus + Grafana** - per-family dashboards (CRUD req/s + p95; real-time concurrent connections; AI GPU util + token throughput + chunk backlog; async task-queue depth), consumer-lag dashboards, and per-tenant cost dashboards surfaced in `admin-ops-service`. Long-term/global metrics via Thanos/Mimir.
- **Loki** - structured JSON logs; every line carries `org_id`, `family`, `version`, and request/trace IDs, so logs are queryable per tenant and per release.
- **Sentry** - release-tagged exception tracking; a canary's error-rate regression is visible per release.
- **SLO dashboards & alerts** routed to PagerDuty: consumer-lag (embedding lag < 5s, alert at 30s), DLQ rate (< 0.1%), per-tenant token-budget/quota, GPU saturation, and **cost** alerts (LLM spend is ~94% of variable cost - *LLM cost per tenant per day* is a monitored, alertable, error-budgeted signal).

Three binding principles: every signal is tenant-attributable (`org_id` on every series/log/span); the three families have three observability profiles; cost is a first-class signal.

---

## 12. SRE practices

- **SLOs per tier** (`_canon/05-capacity-math.md` §11, treated here as circuit-breaker thresholds): CRUD/API **p95 < 300 ms** (p99 < 800 ms), live captions **p95 < 2 s**, agent end-to-end p50 < 2 s / **p95 < 4 s**, RAG **p95 < 500 ms** warm (< 1.5 s cold), token-mint p95 < 250 ms, A2A round-trip p95 < 1.5 s.
- **Error budgets** derived from the per-tier availability SLOs gate releases - a burned budget freezes risky rollout.
- **On-call:** PagerDuty rotation with family-aware escalation (a `rag-service` p95 regression and an `agent-runtime-service` token-budget breach are different incident classes with different responders). The first question on every page is "which tenant(s)?" - answered by `org_id` on every signal.
- **Runbooks & game days:** failover, rollback, DR drills, and chaos exercises live in `runbooks/`.

---

## 13. Cost / FinOps

- **Per-tier cost centers** enforced at the node-pool boundary (`17-cost-and-finops.md`). The **AI tier is an independent cost center** - GPU hardware never shares a pool with CRUD.
- **Autoscale-to-zero where possible** (e.g., dev/ephemeral preview namespaces, idle async workers) and scale-to-min in the passive region.
- **GPU cost levers:** right-sized GPU node pools (L4/A10), Ray Serve batching, weights baked into images (cold start is a load, not a fetch), and the canary strategy that avoids doubling the GPU fleet for blue-green swaps.
- Per-tenant cost dashboards (§11) make margin observable per tenant; runaway agent loops are treated as availability-of-margin incidents.

---

## 14. Security / compliance hooks

- **Network policies** default-deny per namespace; **WAF** at Cloudflare; mTLS via the optional mesh.
- **Audit log archival** to a dedicated regional bucket (`nexus-audit`) with retention per `12-compliance-and-privacy.md`.
- **SOC2 controls in infra:** plan→review→apply with approvals, immutable image promotion by digest, least-privilege IAM (IRSA/Workload Identity), secrets never in git/images, and the standing shift-left scan gates (§9).
- **Tenant isolation invariants** preserved in every networking/storage change: RLS, per-tenant Qdrant collections + `org_id` payload filter, tenant-partitioned Redpanda topics, the `nexus:{org_id}:` Redis prefix, and per-tenant KMS data keys.

---

## 15. Dev practices

- **Terraform hygiene:** `terraform fmt`, `terraform validate`, `tflint`, and `tfsec`/`checkov` on every PR touching `terraform/`.
- **Plan-on-PR + apply-on-merge with approvals** - `apply` runs only from Terraform Cloud after review.
- **Manifest validation:** `helm template` + `kubeconform`/`kubeval`, `kustomize build`, and OPA/conftest policy checks in CI.
- **Conventional commits** and **trunk-based development** - short-lived branches, frequent integration to `main`, which gates the staging deploy.

---

### Canon docs referenced

`16-deployment-and-infrastructure.md`, `15-observability-and-sre.md`, `14-reliability-and-dr.md`, `13-scalability-and-performance.md`, `17-cost-and-finops.md`, `12-compliance-and-privacy.md`, `03-container-architecture.md`, `09-rag-and-inference-serving.md`, `06-multi-tenancy.md`, `07-event-architecture.md`, `11-security-architecture.md`, and the frozen `mytheus-docs` `_canon/` (`01-service-catalog.md`, `02-data-model.md`, `03-event-taxonomy.md`, `05-capacity-math.md`, `06-tech-decisions.md`). ADRs: 0008, 0009, 0014, 0015.
