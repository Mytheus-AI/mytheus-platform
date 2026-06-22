# Reprise AI - Platform & Infrastructure (`reprise-platform`)

> The deployment substrate for all of Reprise AI (internal codename **NEXUS**): Terraform IaC, Kubernetes manifests/Helm charts, CI/CD pipelines, the observability stack, and multi-region DR that runs every other repo's services.

## What this is

`reprise-platform` is the **infrastructure / platform engineering** repo for Reprise AI - an intelligent meeting-orchestration multi-tenant SaaS sized at the frozen capacity anchors (5M registered users, 2M MAU, 20k peak concurrent meetings, 100k peak concurrent participants).

This repo contains **no application code**. It is the substrate the application repos deploy *onto*:

- **Infrastructure as Code (Terraform)** - the cloud substrate: VPCs, EKS/GKE clusters, node pools, managed-data wiring, edge, secrets, observability.
- **Kubernetes + Helm/Kustomize** - how the ~20 canonical services are packaged, scheduled, and isolated per scaling family and per tenant cell.
- **CI/CD (GitHub Actions)** - build/test gates, image promotion by digest, GitOps delivery, family-aware progressive rollout.
- **Observability stack** - OpenTelemetry Collector → Prometheus/Grafana/Loki/Tempo + Sentry, SLO dashboards, and the alert routing that gates releases.
- **Multi-region & DR** - active-passive → active-active topology, per-store replication, RPO/RTO targets, and failover runbooks.

If a service runs in production, the *how* and *where* of it lives here. The *what* lives in the application repos.

## What's in here

| Area | Tooling |
|---|---|
| Cloud substrate (IaC) | Terraform modules + per-environment stacks, remote state in Terraform Cloud, drift detection |
| Service packaging | Helm umbrella chart (one subchart per service) + Kustomize overlays |
| CI/CD pipelines | GitHub Actions workflows: lint/test/scan → build → image publish → GitOps deploy → canary |
| Autoscaling | HPA (CRUD req/s), KEDA scalers (real-time connections, Temporal queue depth, embedding lag), Ray Serve (GPU) |
| Observability stack | OpenTelemetry Collector, Prometheus + Grafana, Loki (logs), Tempo (traces), Sentry (errors) |
| Secrets | External Secrets Operator reconciling from cloud Secrets Manager, rooted in cloud KMS; no secrets in git or images |
| Runbooks | On-call, failover, rollback, and game-day procedures |

## Tech stack

- **IaC & control plane:** Terraform, Terraform Cloud (remote state, plan/apply)
- **Compute:** Kubernetes on AWS EKS / GCP GKE; Railway/Render for the early modular-monolith stage
- **Packaging & delivery:** Helm, Kustomize, Argo CD (GitOps), Argo Rollouts (canary/analysis)
- **CI/CD:** GitHub Actions
- **Edge:** Cloudflare (CDN, WAF, geo + health-checked DNS failover)
- **Autoscaling:** KEDA, HPA, Ray Serve (GPU inference)
- **Observability:** Prometheus / Grafana / Loki / Tempo, OpenTelemetry Collector, Sentry
- **Secrets:** External Secrets Operator + cloud Secrets Manager, cloud KMS (incl. per-tenant data keys), optionally Vault
- **Managed data & service planes wired here:** Supabase Postgres, Qdrant Cloud, Upstash Redis, Redpanda + Schema Registry (BYOC), Temporal Cloud, Clerk, LiveKit, Deepgram, Stripe, LiteLLM (Anthropic / OpenAI)

## Repo structure

```
reprise-platform/
├── terraform/
│   ├── modules/                 # versioned, region-reusable modules (network, cluster, data, edge, secrets, observability)
│   └── environments/
│       ├── dev/
│       ├── staging/
│       └── prod/                # per-region stacks: prod/us, prod/eu, prod/ap
├── k8s/
│   ├── base/                    # Kustomize bases (NetworkPolicy, ResourceQuota, LimitRange per family)
│   └── overlays/                # dev / staging / prod (+ per-region, per-cell) overlays
├── helm/                        # nexus umbrella chart + values-{env}.yaml
├── .github/workflows/           # CI/CD: lint/test/scan, build, publish, deploy, rollout
├── observability/               # OTel Collector, Prometheus rules, Grafana dashboards, alert routing
└── runbooks/                    # on-call, failover, rollback, game-day
```

## Quick start

**Prerequisites:** `terraform`, `kubectl`, `helm`, `kustomize`, and the relevant cloud CLI (`aws` / `gcloud`), plus access to Terraform Cloud and the deployment GitOps repo.

**Plan / apply the cloud substrate (per environment, per region):**

```bash
# Terraform Cloud is the only place apply runs - never a laptop.
cd terraform/environments/prod/us
terraform init
terraform plan      # runs automatically on every PR touching terraform/
terraform apply     # gated on review + approval; executes from Terraform Cloud
```

**Render and validate Kubernetes workloads:**

```bash
helm template nexus ./helm -f helm/values-staging.yaml | kubeconform -strict
kustomize build k8s/overlays/staging | kubeconform -strict
```

Workloads are **not** applied with `kubectl` by hand. CI bumps the image digest in the deployment GitOps repo and Argo CD reconciles each cluster against it.

**The Railway/Render early path:** before the Kubernetes substrate is warranted, Reprise AI runs as a **modular monolith on Railway/Render** with Docker Compose as the local-dev source of truth. Services are then peeled off in the frozen Wave 1–4 order (GPU + real-time + workers → CRUD core → SaaS business → retrieval stores) onto EKS/GKE. See [`system.md`](system.md) and `16-deployment-and-infrastructure.md`.

## Environments

| Environment | Cluster | Regions | Deploy trigger |
|---|---|---|---|
| `dev` | Shared non-prod | single | Per-PR ephemeral preview namespaces (TTL-reaped) |
| `staging` | Shared non-prod | single | On merge to `main` |
| `prod` | Dedicated, per region | `us`, `eu`, `ap` | Manual approval after staging smoke + load gate |

Production placement composes along three axes - **region × environment × cell** - so a tenant's compute runs in the region its data is pinned to, and large/enterprise tenants get dedicated cell node pools. See `12-compliance-and-privacy.md` (data residency) and `14-reliability-and-dr.md`.

## Related repos

`reprise-platform` deploys the other Reprise AI repos. The full set (8):

1. **`reprise-platform`** - this repo: IaC, Kubernetes, CI/CD, observability, DR.
2. **`reprise-docs`** - architecture canon and the frozen `_canon/` naming authority (service, topic, and store names).
3. **`reprise-core-api`** - CRUD / control-plane services (`core-api`, `identity-tenant-service`, `meeting-service`, `billing-metering-service`, `integration-service`, `admin-ops-service`, `notification-service`).
4. **`reprise-realtime`** - real-time tier (`realtime-gateway`, `transcription-service`).
5. **`reprise-ai`** - AI / inference tier (`agent-runtime-service`, `embedding-service`, `reranker-service`, `rag-service`, `ingestion-service`, `knowledge-graph-service`, `search-service`).
6. **`reprise-workflows`** - async orchestration (`workflow-service`, Temporal workers).
7. **`reprise-web`** - `web-app` (Next.js 14) and the `bff`/`api-gateway` edge.
8. **`reprise-sdk`** - shared client/SDK and contracts.

Service, topic, and store names are owned by `reprise-docs` `_canon/`. This repo deploys them under those exact names - it never renames anything.

## License

Proprietary © Reprise AI. All rights reserved.
