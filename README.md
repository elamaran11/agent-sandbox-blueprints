<div align="center">

# Agent Sandbox Blueprints

**Run autonomous coding agents in hardware-isolated sandboxes on Amazon EKS.**

A GitHub issue goes in. A reviewed, tested, merged pull request comes out — written by an AI agent
running inside a micro-VM it cannot escape.

[![License](https://img.shields.io/badge/License-MIT--0-blue.svg)](LICENSE)
[![EKS](https://img.shields.io/badge/Amazon-EKS-FF9900?logo=amazonaws&logoColor=white)](https://aws.amazon.com/eks/)
[![Kata](https://img.shields.io/badge/Kata-micro--VM-1e88e5)](https://katacontainers.io/)
[![Lambda MicroVM](https://img.shields.io/badge/AWS_Lambda-MicroVM-FF9900?logo=awslambda&logoColor=white)](https://aws.amazon.com/lambda/)
[![Nitro Sandbox](https://img.shields.io/badge/EKS_Pod_Isolation-Nitro_Sandbox-FF9900?logo=amazonaws&logoColor=white)](nitro-sandbox/README.md)

</div>

---

## Overview

**Agent Sandbox Blueprints** is a minimal, runnable blueprint for the **Dark Factory** pattern: an
autonomous coding agent that takes a GitHub issue, implements it, tests it, gets it reviewed, and
merges it — with a human approving *evidence*, not diffs.

The agent runs untrusted, LLM-generated code, so it never runs in a shared-kernel container. This
blueprint gives you **three hardware-isolated substrates** for it, behind one identical developer
experience:

| Substrate | What it is | Best for |
|---|---|---|
| **Kata micro-VM** | Hardware-isolated pods on nested-virt EKS nodes — your own kernel per sandbox, three hypervisors (Cloud Hypervisor, QEMU, Firecracker) | Production-ready today; long-lived workspaces; GPU (via QEMU) |
| **AWS Lambda MicroVM** | Serverless Firecracker VMs provisioned on demand, suspended while idle, terminated at merge | Bursty agent work; scale-to-zero economics; no node pool to operate |
| **Nitro Sandbox** *(private preview)* | EKS Pod Isolation: every sandbox pod boots its own microVM on a Nitro-isolated slice of an Auto Mode node, selected with one RuntimeClass | Kata's `kubectl`-native workflow without nested virtualization or a runtime to install |

Pick one, or run them side by side. **The pipeline, review gates, and UX are identical.** The only
difference is a label on the GitHub issue.

> **Why this repo exists.** These pieces exist inside a larger platform, buried under fleet
> management, multi-cluster GitOps, and a dozen addons. This is the same outcome with the fewest
> moving parts: **one cluster, one ArgoCD, one command.**

---

## Architecture

Three layers. Each is independently deployable, and each folder in this repo maps to one.

```mermaid
flowchart TB
    subgraph GH["GitHub"]
        ISSUE["Issue<br/>(labeled)"]
        PR["Pull Request<br/>+ review gates"]
    end

    subgraph PIPE["examples/ — Dark Factory pipeline"]
        SENSOR["Argo Events<br/>sensor"]
        WF["Argo Workflows<br/>df-run / df-run-lambda / df-run-nitro"]
        GATES["holdout · deploy-test<br/>security · devops"]
    end

    subgraph SUB["Sandbox substrates"]
        KATA["kata/<br/>Kata micro-VM<br/>clh · qemu · fc"]
        LMVM["lambda-microvm/<br/>AWS Lambda MicroVM<br/>suspend / resume"]
        NITRO["nitro-sandbox/<br/>Nitro Sandbox<br/>EKS Pod Isolation"]
    end

    subgraph INFRA["infrastructure/ — cluster + platform"]
        EKS["EKS · VPC · Karpenter<br/>Managed ArgoCD / ACK / KRO"]
        ADDONS["agent-sandbox CRDs · Argo<br/>Bifrost · Langfuse · OTel"]
    end

    ISSUE --> SENSOR --> WF
    WF -->|claim sandbox| KATA
    WF -->|provision MicroVM| LMVM
    WF -->|claim sandbox| NITRO
    KATA & LMVM & NITRO -->|agent writes code| PR
    PR --> GATES --> PR
    INFRA --- SUB
    EKS --- ADDONS
```

**The flow:** label an issue → a sandbox is created → the agent clones, implements, tests, and opens
a PR → automated gates review it (hidden-scenario holdout, `terraform validate`/deploy test, security
and DevOps reviewers) → a human approves → it merges and the sandbox is destroyed.

On **Lambda MicroVM**, the VM is *suspended* for the entire review window and *resumed* only when a
fix is requested — you pay for the minutes the agent is actually thinking.

---

## Repository layout

```
infrastructure/     Terraform (VPC, EKS, Karpenter, Managed ArgoCD/ACK/KRO) + GitOps addons
kata/               Kata substrate: 3 VMMs, nested-virt Karpenter pools, sandbox templates
lambda-microvm/     Lambda MicroVM substrate: ACK controller, KRO graph, hook-server image, shim
nitro-sandbox/      Nitro Sandbox substrate: Auto Mode NodePool, RuntimeClasses, sandbox templates, samples
examples/
  dark-factory-kata/    Run the pattern on Kata
  dark-factory-lambda/  Run the pattern on Lambda MicroVM
  dark-factory-nitro/   Run the pattern on Nitro Sandbox
docs/               Architecture, substrate comparison, diagrams, prerequisites, troubleshooting
```

---

## Getting Started

### Prerequisites

- An AWS account in **`us-west-2`** (AWS Lambda MicroVM availability — see [PREREQUISITES](docs/PREREQUISITES.md))
- `terraform` ≥ 1.7, `kubectl`, `aws` CLI v2, [`task`](https://taskfile.dev), `helm`, `gh`
- **EKS Managed capabilities enabled** in your account: ArgoCD, ACK, KRO
- A GitHub repo the agent will work in, and a token — **never committed** (see [secrets](docs/PREREQUISITES.md#secrets))

### 1 — Configure (nothing real is committed)

```bash
cp infrastructure/terraform/example.tfvars infrastructure/terraform/terraform.tfvars
cp infrastructure/gitops/values.example.yaml infrastructure/gitops/values.yaml
# edit both — region, cluster name, your GitOps repo URL
```

### 2 — Create the cluster and platform

```bash
task up          # terraform apply → EKS + Karpenter + Managed ArgoCD/ACK/KRO, then bootstrap addons
```

### 3 — Add a substrate (any or all)

```bash
task kata        # nested-virt Karpenter pools + kata-deploy (clh/qemu/fc) + sandbox templates
task lambda      # lambdamicrovms ACK controller + KRO graph + hook-server image + shim bridge
task nitro       # Auto Mode NodePool + pod isolation RuntimeClasses + sandbox templates
```

`task nitro` needs `enable_auto_mode = true` in `terraform.tfvars` and an account enabled
for the EKS Pod Isolation preview. See [nitro-sandbox/README.md](nitro-sandbox/README.md).

### 4 — Run the Dark Factory

```bash
cp examples/dark-factory-kata/values.example.yaml examples/dark-factory-kata/values.yaml
# edit: target repo, PAT secret, trigger label, model
task demo-kata      # or: task demo-lambda, task demo-nitro
```

Then register the GitHub webhook ([MANUAL-STEPS.md §2](docs/MANUAL-STEPS.md) — one
manual step, because the address does not exist until the cluster does), label an
issue, and watch the PR appear. Full walkthroughs:
[Kata](examples/dark-factory-kata/README.md) · [Lambda MicroVM](examples/dark-factory-lambda/README.md) · [Nitro Sandbox](examples/dark-factory-nitro/README.md)

### Tear down

```bash
task down        # destroys everything, including the sandboxes and node pools
```

---

## Choosing a substrate

| | Kata micro-VM | Lambda MicroVM | Nitro Sandbox |
|---|---|---|---|
| **Isolation** | Own kernel per sandbox (VT-x) | Own kernel per sandbox (Firecracker) | Own microVM per pod (Nitro Enclaves) |
| **Node setup** | Nested-virt Karpenter pools + kata-deploy | None, the VMs are remote | Auto Mode NodePool, nothing installed on the node |
| **Provisioning** | Pre-warmed pool → instant claim | On-demand, ~90 s cold start | Seconds on a node that holds the image; 27 s for the first 1 GB coder on a node; ~45 s with a small image when Auto Mode adds a node |
| **Scale to zero** | Node pool consolidates when idle | **VM suspends between rounds** | Empty nodes go after 10 min, but the warm spare keeps one up (`targetIdle: 0` drops it) |
| **Persistent workspace** | ✅ Volume-backed | ❌ Read-only rootfs (`/tmp` only) | ✅ Volume-backed `Sandbox` (Auto Mode EBS); the Dark Factory coder uses an ephemeral overlay |
| **GPU** | ✅ via `kata-qemu` (VFIO) | ❌ | Not covered here |
| **Maturity** | Production-ready | Preview / pre-GA | Private preview |

Full comparison, benchmark timings, and the VMM capability matrix:
**[docs/SUBSTRATES.md](docs/SUBSTRATES.md)**

---

## Documentation

| Doc | What's in it |
|---|---|
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | The three layers, CRDs, and how the pipeline drives a sandbox |
| [SUBSTRATES.md](docs/SUBSTRATES.md) | Kata vs Lambda MicroVM vs Nitro Sandbox; VMM capability matrix; benchmarks |
| [DIAGRAMS.md](docs/DIAGRAMS.md) | Sequence and flow diagrams for every lifecycle |
| [PREREQUISITES.md](docs/PREREQUISITES.md) | Accounts, quotas, region, GitHub setup, **cost estimate** |
| [MANUAL-STEPS.md](docs/MANUAL-STEPS.md) | The few things not automated, and why each one cannot be |
| [ROADMAP.md](docs/ROADMAP.md) | What's next, and the **known gaps** you will hit |
| [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Every gotcha we hit, and the fix |

---

## Contributing

Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## Security

Found a security issue? See [SECURITY.md](SECURITY.md). Do not open a public issue.

## License

Licensed under the [MIT-0](LICENSE) License.

## Contact

Maintained by [@elamaran11](https://github.com/elamaran11). Questions and feedback via
[GitHub Issues](../../issues).
