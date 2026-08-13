# Agent Sandbox Blueprints — Implementation Plan

> **Status:** DRAFT FOR REVIEW — nothing built yet. Review §9 (open decisions) first; they change the shape of the build.

## 1. Goal

A **single-cluster, opinionated, minimal blueprint** that demonstrates the **Dark Factory** autonomous-coding pattern on **two sandbox substrates**:

- **Kata micro-VM** (hardware-isolated pods on nested-virt nodes)
- **AWS Lambda MicroVM** (serverless Firecracker VMs, pre-GA)

…reproducing the same end-to-end result as the Open Agentic Platform (OAP) with a fraction of its surface area, so someone can `git clone` → run one command → watch a GitHub issue become a reviewed, merged PR.

**Why:** OAP is a full platform (multi-cluster fleet, hub/spoke, ~12 addons, KubeVela/OAM, Crossplane, Backstage, Cognito, LiteLLM). That breadth is the point *there*, but it buries the pattern people actually want to see. This repo is the opposite: **one cluster, the fewest moving parts that still produce the same outcome.**

### Non-goals (deliberately out of scope)
- Multi-cluster / hub-spoke / fleet management
- The OAP addon catalog beyond what Dark Factory needs (no LiteLLM, Cognito, Backstage, agent-gateway, OAM/KubeVela, Crossplane)
- Production hardening (this is a blueprint, not a product)
- Touching the existing OAP Dark Factory PR — **that work stays exactly as-is**; this repo *extracts and simplifies* from it

---

## 2. Design principles

1. **One cluster, one ArgoCD, one command.** `task up` gets you a working cluster; `task kata` / `task lambda` add a substrate.
2. **Terraform for what must exist before Kubernetes; GitOps for everything inside it.** Clean seam, no ambiguity about "where does this live."
3. **Managed capabilities wherever they exist** (Managed ACK, Managed KRO); self-managed **only where forced** (see §5).
4. **Each folder stands alone.** Deploy Kata without Lambda, or Lambda without Kata. No hidden coupling.
5. **Everything gated, nothing surprising.** Substrates are opt-in flags; a fresh clone does nothing expensive until you ask.
6. **No secrets in git**, and `.gitignore` the traps (see §6, the 766 MB lesson).
7. **Document the gotchas, not just the happy path.** The troubleshooting doc is the highest-value artifact for adopters.

---

## 3. Repo structure

Maps 1:1 to the six requirements.

```
agent-sandbox-blueprints/
├── README.md                        # hero: what/why, architecture diagram, 5-min quickstart
├── Taskfile.yml                     # task up | kata | lambda | demo-kata | demo-lambda | down
├── .gitignore                       # .terraform/, *.tfstate, node_modules (the 766MB trap)
├── LICENSE / CONTRIBUTING.md / SECURITY.md
│
├── docs/
│   ├── ARCHITECTURE.md              # the three layers: infra → substrate → pipeline
│   ├── SUBSTRATES.md                # Kata vs Lambda MicroVM: compare, benchmark, when to pick which
│   ├── DIAGRAMS.md                  # mermaid (routing, both substrates, lifecycle sequences)
│   ├── PREREQUISITES.md             # accounts, quotas, region, GitHub setup, cost note
│   ├── TROUBLESHOOTING.md           # every gotcha we hit, with the fix
│   └── ROADMAP.md
│
├── infrastructure/                  # ── REQUIREMENT 1 ──
│   ├── terraform/                   # cluster + things that precede K8s
│   │   ├── vpc.tf  eks.tf  iam.tf  ecr.tf
│   │   ├── capabilities.tf          # Managed ACK + Managed KRO (+ ArgoCD, see §9.2)
│   │   ├── argocd.tf                # bootstrap the root app
│   │   ├── variables.tf outputs.tf versions.tf
│   │   └── README.md
│   └── gitops/                      # everything in-cluster, via ArgoCD
│       ├── bootstrap/               # root app-of-apps + ApplicationSet
│       └── addons/                  # ESSENTIAL ONLY:
│           ├── agent-sandbox-crds/  # upstream Sandbox CRDs + operator (both substrates need this)
│           ├── argo-workflows/      # pipeline engine
│           ├── argo-events/         # GitHub webhook → workflow
│           ├── bifrost/             # LLM gateway (see §9.4)
│           ├── langfuse/            # LLM tracing (optional flag)
│           └── otel-collector/      # traces/metrics (optional flag)
│
├── kata/                            # ── REQUIREMENT 2 ──
│   ├── README.md                    # nested-virt requirement, VMM comparison, GPU notes
│   ├── nodepool/                    # self-managed nested-virt node group + launch template
│   ├── kata-deploy/                 # kata-containers installer + per-VMM configuration
│   ├── runtimeclasses/              # kata-clh | kata-qemu | kata-fc   ← all three
│   └── sandbox/                     # SandboxTemplate + SandboxWarmPool for the Kata coder
│
├── lambda-microvm/                  # ── REQUIREMENT 3 ──
│   ├── README.md                    # pre-GA caveats, ARM64, 8h suspend cap, region
│   ├── ack-controller/              # self-managed lambdamicrovms ACK controller (the ONLY forced self-manage)
│   ├── kro-rgd/                     # MicrovmSandbox ResourceGraphDefinition (schema.group MUST be kro.run)
│   ├── image/                       # hook-server + Dockerfile + artifact publish script
│   ├── shim-bridge/                 # Sandbox-CRD extension: bridge SandboxTemplate + lifecycle controller
│   └── iam/                         # build role, exec role, Pod Identity associations
│
└── examples/                        # ── REQUIREMENT 5 ──
    ├── dark-factory-kata/           # pipeline (df-run) + sensor + sample issue + walkthrough
    └── dark-factory-lambda/         # pipeline (df-run-lambda) + sensor + walkthrough
```

---

## 4. Provenance — what gets extracted from where

Nothing is written from scratch that already works. Sources:

| Destination | Source | Action |
|---|---|---|
| `infrastructure/terraform/` | `eks-platform-openclaw/terraform` (18 files, ~1.5k lines) | **KEEP** `vpc, eks, iam, ecr, argocd, variables, outputs, versions`. **DROP** `cognito*, litellm, bedrock_guardrail, guardrail-overlay, lambda_presignup, external_dns, efs` (~700 lines of unrelated surface). **NEW** `capabilities.tf`. Karpenter → see §9.3 |
| `infrastructure/gitops/addons/` | OAP `gitops/addons/charts/{bifrost,langfuse,otel-collector}` + agent-sandbox upstream CRDs | Extract as-is, strip fleet/hub-spoke labels; single-cluster appset |
| `kata/` | OAP `gitops/addons/charts/agent-sandbox` (nodepool tf, runtimeclasses, sandboxtemplate, warmpool, networkpolicy) | Extract + **add the 3rd VMM (Firecracker — new work, see §9.5)** |
| `lambda-microvm/` | OAP `gitops/addons/charts/agent-sandbox-lambda` (RGD, pod-identity, bridge, lifecycle) + `examples/dark-factory/coder-microvm` | Extract nearly as-is — this is the most mature/isolated piece |
| `examples/dark-factory-*/` | OAP `gitops/addons/charts/dark-factory` (17 templates, scripts, holdout) | **Split** by substrate: `df-run` → kata example, `df-run-lambda` → lambda example. Keep `df-iterate`, `df-merge-teardown`, sensor, scripts, holdout |
| `docs/SUBSTRATES.md`, `docs/DIAGRAMS.md` | OAP `docs/dark-factory/SUBSTRATE-{BENCHMARK,DIAGRAMS}.md` | Port + refresh for single-cluster |
| coder images | OAP `examples/dark-factory/coder{,-microvm}` | Move to `examples/*/image/` or a shared `images/` |

**Simplification levers** (how we get from OAP-scale to blueprint-scale):
- 1 cluster instead of hub + 2 spokes → deletes the entire fleet/`ApplicationSet`-per-environment layer
- 6 addons instead of 12
- no Crossplane (the Kata node group becomes plain Terraform instead of Crossplane-managed)
- no KubeVela/OAM, no Backstage, no Cognito/UI
- flatten `gitops/addons/{bootstrap,environments,clusters,charts,default}` → `gitops/{bootstrap,addons}`

---

## 5. Managed vs self-managed (Requirement 4)

| Component | Choice | Rationale |
|---|---|---|
| **ACK — iam, s3, eks** | **Managed ACK capability** | GA controllers, AWS-operated, nothing to run |
| **KRO** | **Managed KRO capability** | AWS-operated. ⚠️ **Constraint:** Managed KRO's controller only watches the **`kro.run`** API group — the `MicrovmSandbox` RGD's `schema.group` **must** be `kro.run`, or it never leaves `Inactive` ("cache sync timeout") |
| **ACK — lambdamicrovms** | **Self-managed** (forced) | `lambdamicrovms` is **pre-GA**; Managed ACK only bundles GA-upstream controllers. This is the *only* controller we run ourselves. When it goes GA: delete the chart, Managed ACK adopts it, **no RGD change needed** |
| **ArgoCD** | see §9.2 | Managed capability = less ops; Helm = more portable for a public blueprint |
| **Argo Workflows / Events** | Helm | No managed option |
| **Kata node group** | Terraform (self-managed MNG) | Nested virt requires a custom launch template; EKS Auto Mode / Bottlerocket can't provide it |

---

## 6. Constraints to bake in (the "don't repeat our mistakes" list)

Hard-won on OAP; every one of these belongs in `docs/TROUBLESHOOTING.md`.

**Kata**
- Requires **nested virtualization** → self-managed MNG with `cpuOptions.nestedVirtualization`, AL2023 AMI (**not** Bottlerocket), `c8i`/`m8i`-family instance (exposes VT-x)
- **CLH** (`kata-clh`): default, fast boot, **no GPU passthrough**
- **QEMU** (`kata-qemu`): heavier boot, **GPU via VFIO passthrough** — the only GPU-capable VMM
- **Firecracker** (`kata-fc`): smallest/fastest, but **no virtio-fs (no volume sharing)** and **no device passthrough** → see §9.5, this may not run the coder at all
- Kata has **no VM-level suspend/resume today** (upstream WIP). `Sandbox.operatingMode: Suspended` = **delete pod, retain PVC** → cold restart with files intact (same model as Coder/Gitpod), *not* warm hibernation

**Lambda MicroVM**
- **ARM64 only**; region availability (see §9.1)
- Code artifact is an **S3 zip** — overwriting the *same key* does **not** trigger a rebuild → use **versioned keys** and bump `codeArtifactUri`
- **`HTTP_INGRESS`** connector (`ALL_INGRESS` blocks auth-token minting)
- Read-only rootfs → coder must use **`WORKSPACE=/tmp/workspace`** (this one silently killed runs)
- Outside cluster network → **Bedrock-direct** via exec role (can't reach an in-cluster gateway)
- `/run` hook has a **30 s timeout** → background-spawn the coder, poll GitHub for the PR
- **Suspend sticks only if** `idlePolicy.autoResumeEnabled=false` **and** nothing touches the VM endpoint afterwards (any request auto-resumes it)
- `suspendedDurationSeconds` **max 8 h (28800)** — shorter values auto-terminate the VM before a human returns
- **Resume-from-suspend is intermittently flaky** (pre-GA): plan a **recreate-fallback**
- ACK `Microvm.status.state` is **stale** — never trust it; read `aws lambda-microvms get-microvm --query state`
- **One VM per session/issue** — two owners pointing at one VM caused suspend↔resume flapping until the VM died

**Repo hygiene**
- `.gitignore` **`.terraform/`** — OAP has a **766 MB** committed provider directory under `charts/dark-factory/iam/`. Do not inherit that.
- No PATs/tokens in git; document the secret-creation step explicitly

---

## 7. Phased build (retrofit order)

Each phase ends with a concrete, observable check.

| Phase | Deliverable | Done when |
|---|---|---|
| **0. Scaffold** | Repo skeleton, `.gitignore`, LICENSE, Taskfile stub, README outline | `git push` — structure reviewable |
| **1. Infrastructure (TF)** | VPC + EKS + IAM + ECR + Managed ACK/KRO + ArgoCD | `kubectl get nodes` returns Ready; capabilities ACTIVE |
| **2. Infrastructure (GitOps)** | Root app + essential addons | All ArgoCD apps `Synced/Healthy` |
| **3. Kata substrate** | Nested-virt node group, kata-deploy, 3 RuntimeClasses, SandboxTemplate + warm pool | A pod with `runtimeClassName: kata-clh` runs; `kata-qemu` runs; `kata-fc` per §9.5 |
| **4. Lambda substrate** | Self-managed ACK controller, KRO RGD, image build+publish, shim bridge, IAM | A `Microvm` reaches **RUNNING**; hook-server answers `/ready` |
| **5. Example: Kata** | `df-run` pipeline + sensor + sample issue | Labeled issue → PR → review gates → merge |
| **6. Example: Lambda** | `df-run-lambda` + sensor | Issue → PR → **VM SUSPENDED** → fix round → merge → **VM TERMINATED** |
| **7. Docs + OSS prep** | All docs, diagrams, secret audit, cost estimate, CONTRIBUTING/SECURITY | A stranger can follow the README and reproduce phase 5 & 6 |

**Estimated shape:** phases 1–2 are mostly deletion (easy); 3 is the riskiest (Firecracker + nested virt); 4 is a near-copy of working code; 5–6 are extraction + splitting; 7 is writing.

---

## 8. Definition of done

- `git clone` → follow README → **both** demos work in a fresh AWS account (given quotas + a GitHub token)
- Kata and Lambda substrates each deployable **independently**
- Zero secrets in git; zero `.terraform/` bloat
- `docs/SUBSTRATES.md` gives an honest Kata-vs-Lambda decision table (including where Lambda is *not* suitable)
- `docs/TROUBLESHOOTING.md` covers every §6 gotcha
- Publicly presentable: clear README with architecture diagram, no internal/account-specific values hardcoded

---

## 9. Open decisions — need your call before I build

These materially change the work; I don't want to guess.

**9.1 Region.** Lambda MicroVM availability drove us to **us-west-2**. Pin the blueprint to us-west-2, or parameterize with a documented "Lambda MicroVM requires a supported region" note?

**9.2 ArgoCD: Managed capability or Helm?** Managed = less to operate and matches "use managed where possible." Helm = portable to any EKS/any account, better for a public blueprint. **My lean: Helm**, with a note that Managed ArgoCD is a drop-in alternative.

**9.3 Karpenter: include or drop?** Kata needs a self-managed nested-virt MNG regardless, so Karpenter adds a component without serving the demo. **My lean: drop for v1** (fewer moving parts), mention as an optional add-on.

**9.4 Bifrost, or Bedrock-direct for both substrates?** Today Kata goes through Bifrost (gives Langfuse tracing); Lambda is Bedrock-direct (must be). Making **both** Bedrock-direct removes an addon and a failure mode, but loses centralized LLM tracing for Kata. **My lean: keep Bifrost as an optional flag** (default on, because tracing is a genuinely good demo), Bedrock-direct always available.

**9.5 Firecracker — real blocker to check.** You asked for all 3 VMMs. Honest flag: **Kata + Firecracker does not support virtio-fs**, i.e. **no volume sharing into the guest**. The Kata coder currently mounts a `/workspace` volume. So `kata-fc` may be unable to run the coder as-written. Options: (a) ship `kata-fc` RuntimeClass + a *hello-world* validation workload only, documenting the limitation; (b) rework the coder to need no shared volume; (c) document Firecracker as unsupported-for-this-workload. **My lean: (a)** — you get all three VMMs demonstrably installed, with an honest capability matrix.

**9.6 GitHub auth: PAT or GitHub App?** PAT is 3 lines and fine for a demo. A GitHub App is what enterprise/multi-repo actually needs (per your PR review discussion). **My lean: PAT for the quickstart, GitHub App documented as the production path.**

**9.7 External review agents.** The AWS Security/DevOps reviewers are **external GitHub Apps** tied to specific accounts — a public blueprint can't assume them. Make the review gates **pluggable with a default that works without them** (e.g. holdout gate + `terraform validate` + an LLM-judge review), and document how to wire the real agents? **My lean: yes** — otherwise the blueprint is unreproducible for outsiders.

**9.8 Repo visibility / naming.** Repo is `agent-sandbox-blueprints` (private). Is the intended public name the same? Any branding constraints (aws-samples vs personal) that affect LICENSE/CONTRIBUTING boilerplate?

---

## 10. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Kata + Firecracker can't run the coder (no virtio-fs) | Requirement 2 partially unmet | §9.5 option (a): install + validate with a simple workload, document matrix |
| Lambda MicroVM is pre-GA (API churn, resume flakiness) | Example 6 flaky for adopters | Pin versions; ship the recreate-fallback; document clearly as preview |
| External review agents unavailable to public users | Examples not reproducible | §9.7 pluggable gates |
| Nested-virt instance availability/quota in target region | Phase 3 blocked | Document required quotas in PREREQUISITES; pick a widely available family |
| Cost surprise for adopters | Bad first impression | `docs/PREREQUISITES.md` cost estimate + `task down` that actually destroys everything |

---

## 11. Immediate next step

Answer §9 (even just "go with your leans"), and I'll start at **Phase 0** and build up, verifying each phase before moving on.
