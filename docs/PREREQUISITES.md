# Prerequisites

## Tools

| Tool | Minimum | Why |
|---|---|---|
| `terraform` | 1.7 | Creates the cluster and platform IAM |
| `kubectl` | 1.30 | Applies substrates and examples |
| `aws` CLI | v2 | Auth, EKS capabilities, MicroVM inspection |
| `helm` | 3.14 | Renders/validates charts locally |
| [`task`](https://taskfile.dev) | 3 | The one entry point (`task up`, `task kata`, …) |
| `docker` (with buildx) | — | Builds the agent image; **buildx needed for ARM64** if you use Lambda MicroVM |
| `gh` | — | Optional, convenient for creating the demo issue |

`task preflight` checks the required ones and that your config files exist.

## AWS account

**Region: `us-west-2`.** Pinned because AWS Lambda MicroVM is only available in select
regions. The Kata-only path works anywhere nested-virtualization instances exist — change
`region` in `terraform.tfvars` if you are skipping Lambda MicroVM.

### EKS Managed capabilities

This blueprint prefers AWS-run controllers. These must be available to your account and
region:

| Capability | Used for |
|---|---|
| **ARGOCD** | The GitOps engine |
| **ACK** | Declarative IAM + S3 for the Lambda MicroVM substrate |
| **KRO** | Composes those ACK resources into one CRD |

If any is unavailable, set the matching `enable_managed_*` to `false` in
`terraform.tfvars` and install the equivalent yourself — the failure message tells you
which flag to flip.

### Bedrock model access

The agent reasons with Anthropic models on Bedrock. Enable model access in the Bedrock
console for the model in your values (default:
`us.anthropic.claude-sonnet-4-5-20250929-v1:0`). Without it every run fails at the first
model call.

### Service quotas to check

| Quota | Why it matters |
|---|---|
| Running On-Demand Standard instances (vCPU) | Kata nodes are large; the default quota on a fresh account can block provisioning |
| Elastic IPs | The VPC uses one for its NAT gateway |
| VPCs per region | One is created |
| AWS Lambda MicroVM limits | Preview service — concurrent MicroVMs may be limited per account |

**Nested virtualization:** Kata needs it, and not every instance family exposes it. The
`nodepools` values list validated families; if provisioning fails with a capacity error,
try the bare-metal fallback pool.

## GitHub

- A **throwaway repository** for the agent to work in. It opens PRs there, and a merge is
  a real merge. Do not point this at anything that matters.
- A **fine-grained token** scoped to that one repo, plus a **webhook secret** — see
  [`examples/_shared/SECRETS.md`](../examples/_shared/SECRETS.md).
- The cluster's Argo Events endpoint must be reachable from GitHub for webhooks.

### Optional: the AWS review agents

`gates.securityAgent` / `gates.devopsAgent` are external GitHub Apps tied to specific AWS
accounts. They are **off by default** so the blueprint works without them — the holdout
gate and deploy test still exercise the full review loop.

## Cost

This creates real, billable infrastructure. Rough **us-west-2 on-demand** order of
magnitude, running continuously:

| Component | Note |
|---|---|
| EKS control plane | Flat hourly charge per cluster |
| System node group | 2 × `m5.large` |
| **NAT gateway** | Hourly + per-GB — often the biggest surprise on a small cluster |
| Kata nodes | Karpenter-provisioned on demand; consolidate away when idle |
| Lambda MicroVM | Per active minute — **suspended VMs are the point**, but a leaked non-terminated VM keeps billing |
| Bedrock | Per token, per run |
| ECR / S3 | Negligible at this scale |

**Keep the bill sane:**

```bash
# Any MicroVM still alive? (should be empty when idle)
aws lambda-microvms list-microvms --region us-west-2 \
  --query "items[?state!='TERMINATED']" --output table

task down     # deletes sandboxes and MicroVMs first, then destroys the cluster
```

Do not leave a demo cluster running overnight expecting it to be free — Kata nodes and
the NAT gateway bill regardless of whether any agent is working.
