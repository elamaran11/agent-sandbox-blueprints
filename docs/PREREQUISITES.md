# Prerequisites

## Tools

| Tool | Minimum | Why |
|---|---|---|
| `terraform` | 1.7 | Creates the cluster and platform IAM |
| `kubectl` | 1.30 | Applies substrates and examples |
| `aws` CLI | v2 with `bedrock-agentcore-control` | Auth, EKS capabilities, MicroVM and AgentCore Runtime operations |
| `helm` | 3.14 | Renders/validates charts locally |
| [`task`](https://taskfile.dev) | 3 | The one entry point (`task up`, `task kata`, …) |
| [`yq`](https://github.com/mikefarah/yq) | v4 (mikefarah, not the python `yq`) | `task lint:values` normalises the example values trees before diffing them |
| `docker` (with buildx) | — | Builds the agent image; **buildx needed for ARM64** if you use Lambda MicroVM or AgentCore Runtime |
| `gh` | — | Optional, convenient for creating the demo issue |

`task preflight` checks the required ones and that your config files exist.

## AWS account

**Region: `us-west-2`.** Pinned because AWS Lambda MicroVM is only available in select
regions. The Kata-only path works anywhere nested-virtualization instances exist — change
`region` in `terraform.tfvars` if you are skipping Lambda MicroVM.

For AgentCore, confirm **AgentCore Runtime is enabled** in your target account
and region. V2 (used by `task agentcore` after ACK creates the runtime) is
available in `us-east-1`, `us-east-2`, `us-west-2`, `eu-west-1`, and
`ap-northeast-1`. Build and push the shared coder for `linux/arm64` to the
`coder_microvm` ECR repo; `task agentcore` publishes the digest-pinned host
image on top of it. The Managed ACK capability must include the `bedrockagentcorecontrol`
controller (it does as of capability version 46.184.0; check with
`kubectl get crd agentruntimes.bedrockagentcorecontrol.services.k8s.aws`). VPC mode also
requires `enable_agentcore_vpc=true` in Terraform and **private subnets in
AgentCore-supported AZs**; PUBLIC is the default. In the live `us-west-2` run,
the three private subnet AZ IDs were `usw2-az1`, `usw2-az2`, and `usw2-az3`.
AgentCore uses `AWSServiceRoleForBedrockAgentCoreNetwork` to manage VPC ENIs;
the runtime execution role does not need EC2 ENI actions. Private subnets
need NAT egress to reach GitHub, Bedrock, and ECR in this blueprint. After a
switch back to PUBLIC, AWS-managed ENIs can hold the security group for up to
eight hours; defer the targeted Terraform SG removal until they disappear.

### EKS Managed capabilities

This blueprint prefers AWS-run controllers. These must be available to your account and
region:

| Capability | Used for |
|---|---|
| **ARGOCD** | The GitOps engine |
| **ACK** | Declarative IAM + S3 for the Lambda MicroVM substrate |
| **KRO** | Composes those ACK resources into one CRD |

If Identity Center runs in a different region from the EKS cluster, set
`argocd_idc_region` in `terraform.tfvars` to that region. Managed ArgoCD uses
it to resolve `argocd_idc_instance_arn` and the admin identities.

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
| AgentCore Runtime availability and concurrent sessions | Check this account and region before enabling the third substrate |

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

`securityAgent` and `devopsAgent` use external GitHub Apps tied to specific AWS
accounts; both flags default to false. Set `review.enabled: false` at the top
level of your example's gitignored `values.yaml` until the Apps are installed:
the master review switch defaults to true, and leaving it on adds DAG tasks
that wait for absent App verdicts. Apply the same override under
`dark-factory-shared:` for shared values. Holdout can run without either App.

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
| AgentCore Runtime | Check runtime/session pricing for your region; coder sessions stop after each round |
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
