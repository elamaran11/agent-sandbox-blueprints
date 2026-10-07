# Dark Factory — Substrate comparison: Kata, Lambda MicroVM, AgentCore Runtime

A side-by-side comparison of three substrates that run the autonomous coder.
Kata and Lambda were measured on identical issues run through the same cluster.

The Kata/Lambda timings below are measured runs. The AgentCore VPC timing is
from a different issue and is not a head-to-head benchmark.

**AgentCore verified scope:** Managed ACK/KRO created the platform runtime;
PUBLIC and VPC network modes, V2 snapshot setup, initial issue-to-PR runs,
a fix round, and label-triggered runs were exercised live. The substrate has
two IAM roles: runtime execution and workflow invocation. Review App behavior
depends on whether those external Apps are installed in the target repository.

- **Kata substrate — Kata micro-VM** (mature, default): the agent runs in a hardware-isolated Kata
  pod on a self-managed nested-virt EKS node group.
- **Lambda MicroVM substrate — AWS Lambda MicroVM** (pre-GA): the agent runs in a Firecracker MicroVM
  provisioned via the `lambdamicrovms` ACK controller, driven by a bridge pod.
- **AgentCore Runtime substrate — microVM compute**: the agent runs in a
  disposable AgentCore session provisioned by an ACK `AgentRuntime` through KRO.

All three run the **same `dark-factory-coder`** (same `entrypoint.js`), produce the same kind of
PR, and go through the **same review gates** (AWS DevOps Agent + AWS Security Agent). The only
difference is *where the agent executes* and *how it's provisioned*.

---

## TL;DR

| | Kata micro-VM | Lambda MicroVM | AgentCore Runtime (microVM compute) |
|---|---|---|---|
| **Workflow** | `df-run` (certified) | `df-run-lambda` (separate, MicroVM-native) | `df-run-agentcore` (live-verified in PUBLIC and VPC modes) |
| **Provisioning** | pre-warmed pool → **instant claim** | **RunMicrovm cold-start per session** (~90s) | ACK + KRO create one runtime; a V2 PUBLIC → VPC update took ~9m25s to READY; snapshot restores on fresh sessions |
| **Time to first PR** (from label) | ~**2 min** | ~**2.5 min** | VPC issue #9: **2 min** (different issue; not a controlled comparison) |
| **LLM path** | Bifrost gateway (in-cluster) + Langfuse traces | **Bedrock-direct** (exec role) — no cluster network | **Bedrock-direct** (runtime execution role), in PUBLIC or VPC mode |
| **Scale-to-zero when idle** | ❌ node pool runs continuously | ✅ **suspend-to-zero** between PR and merge | Session stops after coder; runtime remains available for later sessions |
| **Fix-round mechanic** | fresh pod each round | **resume the SAME suspended VM** (warm); recreate if the pre-GA resume fails | New session each round; GitHub holds branch and review state |
| **Infra to manage** | nested-virt node group (Karpenter/MNG) | none — serverless MicroVMs | Managed ACK, one KRO runtime; no agent node pool |
| **Observability** | native `kubectl logs` | custom `/logs` HTTP endpoint (no runtime CloudWatch) | AgentCore runtime CloudWatch logs |
| **Maturity** | production-ready today | pre-GA (preview) — pilot-grade | PUBLIC/VPC and V2 live-verified; operational cleanup needs care |
| **Limits** | Node pool and pod configuration | Service quotas | Factory reports 2 vCPU / 8 GB RAM / ~8 GB disk (not measured here) |
| **When to pick** | In-cluster access and persistent workspaces | Serverless with suspend/resume | Disposable rounds and direct Bedrock; no retained workspace |

**Bottom line:** at small scale the two feel equivalent (the LLM coding step ~2–4 min and the
external review agents ~8–15 min take most of the total time on *both*). The Lambda substrate's advantage
is **not latency** — it's **operational + economic**: no node pool to run, and suspend-to-zero
between the PR and the human's review/merge. Its cost is **maturity** (pre-GA control plane — resume
from suspend is occasionally flaky, mitigated by the recreate-fallback) and the extra plumbing below.

---

## Measured runs (Kata/Lambda same issue; AgentCore different issue)

### Time to first PR (from label → PR opened)
| Substrate | Issue | PR | Elapsed | Notes |
| --- | --- | --- | --- | --- |
| Kata | #137 | — | ~**2 min** | pre-warmed pod, instant claim |
| Lambda | #135 | #136 | ~**2.5 min** (20:53:03 → 20:55:35) | native `df-run-lambda`, RunMicrovm cold-start |
| AgentCore VPC | — | — | **2 min** (20:58:55 → 21:00:55 UTC) | Different issue; workflow 20:58:58 → 21:02:15 (3m17s), implementation + holdout SUCCESS |

**Kata vs Lambda Δ ≈ 30–90s** — the MicroVM cold-start (`RunMicrovm` → RUNNING → `/run`) vs Kata's pre-warmed pod
claim. Note the MicroVM-native `df-run-lambda` is **faster than the old bridge path** (~3.7 min):
removing the SandboxClaim/warm-pool indirection cut ~1 min. Everything after (clone → LLM → push) is
identical code and takes the same time.

### Lifecycle timing (Lambda #135, native pipeline)
| Phase | Time |
| --- | --- |
| provision-microvm (RunMicrovm → RUNNING → `/run` HTTP 200) | ~90s |
| **drive-coder** (clone → LLM → push → PR) | ~60s |
| suspend-microvm (VM → SUSPENDED, stays down) | ~5s |
| holdout / deploy-test (terraform validate) | ~20–40s each |
| security-agent + devops-gate (external) | ~8–15 min combined (takes most of the time) |
| fix round: resume-or-recreate + coder re-run → new commit | ~2 min |

*(The external review agents take most of the wall-clock time on BOTH substrates. The MicroVM is SUSPENDED
for the entire multi-minute review window — that idle time is free on Lambda, billed on Kata.)*

---

## Where the logs are

| What | Kata (Kata substrate) | Lambda (Lambda MicroVM substrate) | AgentCore Runtime |
| --- | --- | --- | --- |
| Pipeline steps | Argo UI (`/argo-workflows`) or `kubectl logs -n argo <pod>` | **same** | **same** |
| Coder output | `kubectl logs -n agent-sandbox-system df-issue-<id>` (native) | **`GET https://<vm-endpoint>/logs`** with an auth token (runtime CloudWatch routing is unreliable on the pre-GA runtime, so the hook-server captures coder stdout to a file + serves it) | CloudWatch `/aws/bedrock-agentcore/runtimes/` |
| Image build | n/a (normal ECR image) | CloudWatch `/aws/lambda/microvms/coder-image` | ECR `repo@sha256:...` from `task agentcore-image` |

---

## DAG — three SEPARATE WorkflowTemplates (one per substrate)

The substrates run **different Argo WorkflowTemplates**, so each graph is clean and Kata's certified
pipeline is never touched by Lambda MicroVM substrate changes. The Argo Events sensor routes by label:
`dark-factory` → `df-run` (Kata), `darkfactory-lambda` → `df-run-lambda` (Lambda MicroVM substrate),
`darkfactory-agentcore` → `df-run-agentcore` (AgentCore Runtime).

**Kata — `df-run` (certified, byte-identical to the mature pipeline):**
```
claim(SandboxClaim) → drive-coder → { holdout, devops-gate → security, detect → deploy-test } → status → onExit(teardown: delete claim)
```

**Lambda — `df-run-lambda` (MicroVM-native; NO SandboxClaim / bridge / warm pool):**
```
provision-microvm → drive-coder → suspend-microvm → { holdout, devops-gate, security, detect → deploy-test } → status → onExit(keep suspended VM)
```
The one extra node — `suspend-microvm` — is **explicit and lives only in the Lambda graph**, so the
Kata graph still contains zero MicroVM nodes. Suspend/resume is owned by the workflow directly (it
calls `aws lambda-microvms suspend/resume-microvm`), not a bridge or a lifecycle controller.

**AgentCore — `df-run-agentcore` (runtime-native; no SandboxClaim):**
```
invoke-agentcore → await-coder (GitHub PR) → { stop-agentcore-session ∥ holdout ∥ devops-gate ∥ security ∥ detect → deploy-test } → status → onExit(stop session again)
```
ACK creates the runtime once through KRO. The workflow invokes a disposable session per
round with its workflow UID; the host starts `entrypoint.js` and answers `/ping`
with `HealthyBusy` until the coder finishes. GitHub carries the branch between
rounds. Default idle timeout is 15 minutes, with an eight-hour maximum lifetime.
PUBLIC network mode is the default; VPC mode uses Terraform's private subnet IDs
and egress-only security group, injected by `task agentcore` after enabling
`enable_agentcore_vpc`. Both modes invoke Bedrock directly through the execution role.
The `us-west-2` VPC run used supported AZ IDs `usw2-az1`, `usw2-az2`, and
`usw2-az3`; AgentCore's network service-linked role created three ENIs. The
runtime execution role did not need EC2 permissions. Switching back created
a PUBLIC V2 version; the prior VPC version's ENIs remained attached after the
switch and after deleting that unused version. AWS documents up to eight hours
for ENI release, so Terraform cannot remove the VPC security group immediately.

### Substrate-specific mechanics
- **Kata:** `claim-sandbox` binds a **pre-warmed** pod from `coder-warmpool`; the operator injects
  `DF_*` env; the baked `entrypoint.js` runs in-cluster, reaches models via **Bifrost**, native logs.
- **Lambda:** `provision-microvm` (a single workflow step, running as `dark-factory-workflow` with the
  lambda-microvms role via Pod Identity) does it all — no bridge pod, no warm pool:
  1. reads the platform image handoff (imageARN + execRoleARN, built **once** by KRO/ACK),
  2. creates the **`Microvm` CR** (stable name `mvm-<issue-number>`) + a runHookPayload Secret
     (the review note is folded in here — the agent has no claim env),
  3. waits RUNNING + endpoint, mints an auth token, **POSTs `/run`** → the hook-server
     background-spawns the same `entrypoint.js` with `USE_BEDROCK=1` (Bedrock-direct, no cluster net),
  4. the `suspend-microvm` DAG step suspends the VM once the PR is open (idlePolicy
     `autoResumeEnabled=false` + nothing polls the endpoint → it **stays** suspended),
  5. on a fix round `provision-microvm` **resumes the same suspended VM** (warm resume); if the
     pre-GA service failed the resume (VM terminated), it **recreates a fresh VM** automatically,
  6. `df-merge-teardown` deletes the `Microvm` CR at merge → controller `TerminateMicrovm`.

---

## Step-by-step: what actually happens

### Kata (Kata substrate) — `df-run`
1. Issue labeled `dark-factory` → sensor dep `issue-labeled-kata` → `df-run`.
2. `claim-sandbox` binds a **pre-warmed** Kata pod from `coder-warmpool` (instant).
3. Operator injects `DF_*` → baked `entrypoint.js`: clone → Claude Code (via **Bifrost**) → **open PR**.
4. Review gates: DevOps Agent + Security Agent → consolidated verdict.
5. "fix findings" → `df-iterate` → **new** Kata coder round → re-review.
6. Approve → `df-merge-teardown` merges + deletes the claim.

### Lambda MicroVM (Lambda MicroVM substrate) — `df-run-lambda`
1. Issue labeled `darkfactory-lambda` → sensor dep `issue-labeled-lambda` → `df-run-lambda`.
2. `provision-microvm` creates the `Microvm` CR → controller `RunMicrovm` (**cold-start ~90s**) →
   RUNNING; mints token; `POST /run` → hook-server spawns the agent (`USE_BEDROCK=1`,
   **Bedrock-direct**). Coder: clone → Claude Code → **open PR**.
3. `suspend-microvm` step suspends the VM → it **stays SUSPENDED** while gates run (scale-to-zero).
4. Same review gates + verdict.
5. "fix findings" → `df-iterate` → `df-run-lambda` fix round: **resume the SAME VM** (warm) or, if the
   pre-GA service failed the resume, **recreate fresh**; the agent re-runs with the note → new commit.
6. Approve → `df-merge-teardown` merges + deletes the `Microvm` CR → controller `TerminateMicrovm`.

---

## Gotchas the Lambda substrate needed (that Kata does not)

Because a MicroVM is **outside the cluster network, has a read-only rootfs, and uses a
snapshot/hook execution model**:

| # | Gotcha | Fix |
| --- | --- | --- |
| 1 | Coder crashed `EACCES mkdir /workspace/artifacts` (no writable volume like Kata) | set `WORKSPACE=/tmp/workspace` (writable tmpfs) — *the silent killer* |
| 2 | Can't reach Bifrost's ClusterIP from a MicroVM | **Bedrock-direct** via the exec role (`bedrock:InvokeModel`); no Bifrost/NLB/VPC-connector |
| 3 | Runtime logs don't reach CloudWatch | hook-server captures coder stdout → `/logs` HTTP endpoint |
| 4 | The agent is one-shot but the MicroVM `/run` hook has a 30s timeout | `/run` **background-spawns** the agent + returns fast; pipeline polls GitHub for the PR |
| 5 | Ingress: `ALL_INGRESS` blocks auth-token minting | use **`HTTP_INGRESS`** |
| 6 | aws-cli image lacks `lambda-microvms`; no node | step image = `aws-cli:latest` (has the verbs) + python3 for JSON + fetch kubectl at start |
| 7 | `runHookPayload` is a `SecretKeyReference`; imperative `run-microvm --run-hook-payload` doesn't fire `/run` | deliver via the **declarative `Microvm` CR** |
| 8 | Image rebuild: overwriting the same S3 key doesn't rebuild | use versioned artifact keys; bump `codeArtifactUri` |
| 9 | **VM would not stay SUSPENDED** (console showed RUNNING) | `idlePolicy.autoResumeEnabled=false` **and** never hit the VM endpoint after `/run` — any request auto-resumes it |
| 10 | **VM auto-terminated before the fix round** (resume hit "already terminated") | `suspendedDurationSeconds=28800` (Lambda's 8h max) so it survives the review→human window; 5 min was far too short |
| 11 | **Fix round re-ran but committed nothing** (coder "done" on old sha) | the review note must ride on the **runHookPayload** (MicroVM has no claim env); hook-server keys its `/run` guard on a **per-invocation run-id** so a resumed VM accepts a fresh run |
| 12 | Pre-GA **resume-from-suspend is intermittently flaky** (Internal service error → VM terminates) | `provision-microvm` checks the VM's real AWS state and **recreates a fresh VM** when resume isn't possible — the fix round self-heals |
| 13 | Two Sandboxes fought over one VM → suspend/resume **flapped** until the VM died | name the CR/workflow by **issue-number** (stable across rounds) so there's exactly **one VM per issue** |
| — | IAM: the workflow SA calls the lambda-microvms verbs | Pod Identity binds `dark-factory-workflow` → the lambda-microvms role (get/suspend/resume/terminate-microvm + create-auth-token); exec role keeps `bedrock:InvokeModel` |

> **Note on the ACK CR status:** `Microvm.status.state` is **stale** — it does not reflect
> suspend/resume/terminate. Always read AWS truth with `aws lambda-microvms get-microvm --query state`.

Kata needs **none** of these — it's an in-cluster pod with a mounted workspace, native logs,
Bifrost reachability, and a normal ECR image. That's why the two substrates are **separate
WorkflowTemplates** (`df-run` vs `df-run-lambda`): Lambda MicroVM substrate's plumbing never touches the certified Kata graph.

---

## When to choose which

- **Kata (today):** production-ready, mature, standard `kubectl`/IDE access, in-cluster networking.
  Choose it now for reliability. Cost: you run + pay for a nested-virt node pool continuously.
- **Lambda MicroVM (strategic):** serverless, suspend-to-zero per idle session, no node pool —
  the model that scales economically to thousands of sessions. Choose it as it reaches GA. Cost
  today: pre-GA control-plane maturity + the plumbing above.
- **AgentCore Runtime (pilot):** choose disposable coder rounds with direct Bedrock
  and V2 snapshot-based session starts instead of suspended workspaces. The
  runtime remains provisioned; sessions stop after each round. Validate the
  region, VPC AZ support if used, and the Factory-reported 2 vCPU / 8 GB RAM /
  ~8 GB disk limits for your workload. One VPC-mode end-to-end result is recorded above.

Both share the **same coder, same pipeline, same review gates, same UX** — so migrating between
substrates is a label change, invisible to the developer/issue author.
