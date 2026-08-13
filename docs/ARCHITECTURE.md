# Architecture

Three layers. Each maps to one folder and is independently deployable.

```
infrastructure/   the cluster and platform      (Terraform + ArgoCD)
kata/             substrate A: Kata micro-VMs   (opt-in)
lambda-microvm/   substrate B: Lambda MicroVMs  (opt-in)
examples/         the Dark Factory pipeline     (opt-in, per substrate)
```

## The seam between Terraform and GitOps

Deliberately sharp, so there is never a question about where something belongs:

| Terraform | ArgoCD |
|---|---|
| Things that must exist **before** Kubernetes: VPC, EKS, IAM, ECR, EKS Managed capabilities | Everything that **runs on** Kubernetes |

Terraform creates exactly one in-cluster object: the ArgoCD root `Application`. Everything
else is reconciled from git.

## The sandbox contract

Both substrates implement the same three upstream CRDs, which is why the pipeline does not
care which one it is running on:

| CRD | Meaning |
|---|---|
| `SandboxTemplate` | A blueprint for a sandbox (pod spec + policy) |
| `SandboxClaim` | "Give me a sandbox from that template", plus env to inject |
| `Sandbox` | The materialized sandbox. `spec.operatingMode` is `Running` \| `Suspended` |

**Kata** implements this natively: a `Sandbox` *is* a pod, running under a Kata
`RuntimeClass` on a nested-virt node.

**Lambda MicroVM** cannot — the sandbox is a remote AWS resource, not a pod. So the
`SandboxTemplate` there materializes a small **bridge pod** that creates a `Microvm` CR,
waits for the VM, mints an auth token, and drives the agent over HTTP. A separate
controller translates `Sandbox.operatingMode` into `suspend-microvm` / `resume-microvm`,
because those are imperative SDK calls that ACK does not reconcile.

That asymmetry is the single most important thing to understand about this repo. See
[SUBSTRATES.md](SUBSTRATES.md) for the consequences.

## The pipeline

Substrate-agnostic. One `WorkflowTemplate` per substrate differing only in how the
sandbox is obtained; everything after is shared.

```
issue labeled
  → Argo Events sensor        (routes by label to the right substrate)
  → Argo Workflow             (claim/provision sandbox → drive agent)
  → agent opens a PR          (it self-reports through GitHub; it has no cluster creds)
  → gates                     (holdout · deploy test · optional external reviewers)
  → consolidated verdict      (one sticky PR comment)
  → human approves            (the only thing that can cause a merge)
  → merge + teardown
```

**The agent is credential-less to Kubernetes.** No ServiceAccount token is projected into
the sandbox, so it cannot talk to the API server; GitHub is the completion bus. The only
step with cluster write access is the deploy test, and it works in an ephemeral namespace.

## Isolation boundaries

| Boundary | Mechanism |
|---|---|
| Agent ↔ host kernel | Kata micro-VM or Firecracker MicroVM — own kernel, not a shared-kernel container |
| Agent ↔ cluster | No SA token; NetworkPolicy denies the control plane and instance metadata |
| Agent ↔ AWS | Kata: no AWS creds (models via the in-cluster gateway). Lambda: a scoped execution role for Bedrock only |
| Agent ↔ your repo | One fine-grained, repo-scoped GitHub token |
| Unreviewed code ↔ main | A human approval event is required to merge |
