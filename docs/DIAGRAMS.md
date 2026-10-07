# Dark Factory — Substrate Diagrams (Kata, Lambda MicroVM, AgentCore Runtime)

Visual companion to [`SUBSTRATES.md`](./SUBSTRATES.md). All diagrams are
Mermaid (render on GitHub).

---

## 1. Label-routed to three SEPARATE WorkflowTemplates

The Argo Events sensor routes each label to a **different** WorkflowTemplate, so Kata's certified
pipeline is never touched by Lambda MicroVM substrate. Kata keeps its SandboxClaim; Lambda provisions a MicroVM directly.

```mermaid
flowchart TD
    ISSUE["GitHub issue labeled"] --> SENSOR["Argo Events sensor"]
    SENSOR -->|"dark-factory<br/>(issue-labeled-kata)"| DFRUN["df-run<br/>(certified Kata)"]
    SENSOR -->|"darkfactory-lambda<br/>(issue-labeled-lambda)"| DFRUNL["df-run-lambda<br/>(MicroVM-native)"]
    SENSOR -->|"darkfactory-agentcore<br/>(issue-labeled-agentcore)"| DFRUNA["df-run-agentcore<br/>(runtime session)"]
    DFRUN --> KCLAIM["claim-sandbox<br/>(warm Kata pod)"] --> KCODE["drive-coder"]
    DFRUNL --> PROV["provision-microvm<br/>(create Microvm CR + POST /run)"] --> LCODE["drive-coder"]
    DFRUNA --> INV["invoke-agentcore<br/>(new runtime session)"] --> ACODE["await-coder<br/>(GitHub PR)"]
    ACODE --> STOP["stop-agentcore-session"]
    ACODE --> GATES
    LCODE --> SUSP["suspend-microvm<br/>(scale-to-zero)"]
    KCODE --> GATES["holdout · detect→deploy-test<br/>devops-gate · security-agent"]
    SUSP --> GATES
    GATES --> STATUS["status (consolidated verdict)"]
    STATUS --> EXIT["onExit: Kata deletes claim ·<br/>Lambda KEEPS suspended VM ·<br/>AgentCore stops session"]
```

The Kata graph has **zero MicroVM nodes**. `suspend-microvm` is explicit and lives only in
`df-run-lambda`; suspend/resume is driven by the workflow itself (§4), not a bridge or controller.

---

## 2. Kata micro-VM substrate (Kata substrate)

```mermaid
flowchart LR
    CLAIM["SandboxClaim"] --> OP["agent-sandbox operator"]
    OP --> POD["Kata pod (kata-clh)<br/>on nested-virt node group"]
    POD --> ENT["entrypoint.js (baked)"]
    ENT -->|models| BIF["Bifrost gateway<br/>(ClusterIP, in-cluster)"]
    BIF --> BED["Bedrock"]
    ENT -->|git/gh :443| GH["GitHub → PR"]
    ENT -->|secrets| SEC["/etc/secrets<br/>(projected tmpfs)"]
    POD -.native logs.-> KL["kubectl logs"]
    BIF -.traces.-> LF["Langfuse"]
```

- Pre-warmed pod → **instant claim**.
- Workspace is a **mounted writable volume**; logs are native; models via Bifrost (with Langfuse
  traces). Node pool runs continuously.

---

## 3. Lambda MicroVM substrate (Lambda MicroVM substrate) — MicroVM-native, no bridge

```mermaid
flowchart LR
    PROV["provision-microvm step<br/>(dark-factory-workflow SA<br/>+ lambda-microvms role)"] -->|reads handoff| IMG["MicrovmSandbox status<br/>imageARN + execRoleARN<br/>(built once by KRO/ACK)"]
    PROV -->|creates mvm-&lt;issue-number&gt;| MCR["Microvm CR<br/>(runHookPayload = Secret ref,<br/>autoResume=false)"]
    MCR --> CTRL["lambdamicrovms controller"]
    CTRL -->|RunMicrovm cold-start| VM["Firecracker MicroVM<br/>hook-server :8080"]
    PROV -->|mint token, POST /run| VM
    VM --> ENT["entrypoint.js (USE_BEDROCK=1)"]
    ENT -->|models, direct| BED["Bedrock<br/>(exec role, public egress)"]
    ENT -->|git/gh :443| GH["GitHub → PR"]
    VM -.coder stdout.-> LOGS["GET /logs (token)"]
    SUSP["suspend-microvm step<br/>(after PR)"] -->|suspend-microvm| VM
    MERGE["df-merge-teardown<br/>(at merge)"] -->|delete CR| TERM["controller TerminateMicrovm"]
```

- One workflow **step** (`provision-microvm`) does create + drive `/run` — **no bridge pod, no
  SandboxClaim, no warm pool**. `RunMicrovm` cold-start per session (~90s); no node pool.
- No cluster network dependency — **Bedrock-direct**. Logs via `/logs`. The explicit
  `suspend-microvm` step suspends after the PR; the VM stays suspended (autoResume=false) until a fix
  round resumes it or merge terminates it.

---

## 3b. AgentCore Runtime substrate — disposable sessions

```mermaid
flowchart LR
    KRO["agentcore/ KRO AgentCoreSandbox"] --> ACK["ACK AgentRuntime + execution role"]
    INV["df-run-agentcore invoke-agentcore"] -->|"workflow UID session"| ACK
    ACK --> HOST["AgentCore microVM host<br/>/ping and /invocations"]
    HOST --> CODE["entrypoint.js"]
    CODE -->|"models: direct, execution role"| BED["Bedrock"]
    CODE -->|"branch and feedback"| GH["GitHub → PR"]
    GH --> GATES["shared review gates"]
    GH --> STOP["stop-agentcore-session<br/>after coder + onExit"]
    STOP --> ACK
```

The host reports `HealthyBusy` while the coder runs. A new round starts a new
session; GitHub holds the branch and feedback. `PUBLIC` is the default network
mode; `VPC` uses private subnets and the Terraform egress security group. V2
restores an idle snapshot for each session. See the
[verified scope](./SUBSTRATES.md).

---

## 4. Lambda suspend / resume (workflow-driven; warm resume + recreate-fallback)

```mermaid
sequenceDiagram
    participant W as df-run-lambda (workflow)
    participant C as lambdamicrovms controller
    participant V as MicroVM
    W->>C: provision: create Microvm CR (autoResume=false)
    C->>V: RunMicrovm (cold-start)
    V-->>W: RUNNING + endpoint
    W->>V: POST /run (token) → coder starts → PR
    W->>V: suspend-microvm step
    Note over V: SUSPENDED — stays down (no endpoint polling)
    Note over W,V: review gates run while VM is suspended (free)
    Note over W,V: FIX ROUND (df-iterate → df-run-lambda):
    W->>V: resume-microvm (warm — SAME VM)
    alt resume OK (pre-GA happy path)
        V-->>W: RUNNING → POST /run → coder re-runs → new commit
    else resume fails (pre-GA flakiness → VM terminated)
        W->>C: recreate: fresh Microvm CR
        C->>V: RunMicrovm → coder re-runs → new commit
    end
    W->>C: at merge (df-merge-teardown): delete Microvm CR
    C->>V: TerminateMicrovm
```

The CR is named `mvm-<issue-number>` (stable across rounds) → exactly one VM per issue, so
suspend/resume never flap between competing owners.

---

## 5. End-to-end lifecycle (issue → PR → fix → merge) — all three substrates

```mermaid
flowchart TD
    A["Issue labeled"] --> B["df-run: claim + coder → PR"]
    B --> C["DevOps Agent + Security Agent review"]
    C --> D{"Security findings?"}
    D -->|clean| APR["Human approves PR"]
    D -->|findings| FIX["Human comments 'fix findings'"]
    FIX --> IT["df-iterate → df-run (same substrate via trigger-label)"]
    IT --> B
    APR --> MERGE["df-merge-teardown:<br/>merge PR + release/terminate sandbox"]
```

The loop is the same for all three; `df-iterate` reads the originating issue's label to
route the fix round back to the **same** substrate (Kata pool, Lambda MicroVM, or AgentCore Runtime).

---

## Legend / key facts

- **Warm pool:** Kata = ready pods (instant); Lambda and AgentCore launch remote compute without a warm pool.
- **LLM:** Kata → Bifrost (traced in Langfuse); Lambda → Bedrock-direct (exec role).
- **Workspace:** Kata → mounted volume; Lambda → `/tmp/workspace` (read-only rootfs).
- **Logs:** Kata → `kubectl logs`; Lambda → `/logs` endpoint (+ build logs in CloudWatch).
- **Teardown:** Kata → release claim; Lambda → delete `Microvm` CR → TerminateMicrovm.
- **AgentCore:** no warm pool or suspended workspace; each round invokes and stops
  a fresh session, with CloudWatch runtime logs and Bedrock-direct inference.
