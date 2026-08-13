# Platform GitOps

ArgoCD owns everything that runs on the cluster. Terraform creates only the cluster and one root
Application; from there, ArgoCD reconciles this directory.

```
bootstrap/          the root Application (applied by `task gitops:bootstrap`)
platform/           a Helm chart whose templates are ArgoCD Applications (app-of-apps as a chart)
values.example.yaml copy → values.yaml (gitignored) to override anything
```

## How configuration reaches the cluster without being committed

There is a real tension in GitOps: **ArgoCD reads manifests from git**, so a `values.yaml` that is
gitignored is invisible to it. This blueprint resolves that by separating three kinds of config:

| Kind | Example | Where it lives | Committed? |
|---|---|---|---|
| **Safe defaults** | which addons are on, chart versions, namespaces | `platform/values.yaml` | ✅ yes — it must be, for ArgoCD to read it |
| **Your overrides** | your repo URL, region, toggles | `values.yaml` (you create) → injected by Terraform as **inline `helm.valuesObject`** on the root Application | ❌ no |
| **Secrets** | GitHub PAT, webhook HMAC | a Kubernetes **Secret** you create out-of-band, referenced **by name** only | ❌ never |

So: non-secret overrides ride into the cluster through the root Application that Terraform creates
(they end up in the cluster and in Terraform state, but never in git). Secrets never travel through
values at all — manifests only ever reference a Secret *name*.

> If you would rather keep overrides in git (a private fork, for example), just edit
> `platform/values.yaml` directly and skip the injected file. Secrets still stay out.

## Layers

Applications are ordered with ArgoCD sync waves so dependencies land first:

| Wave | Application | Why this order |
|---|---|---|
| `0` | `agent-sandbox` | Installs the `Sandbox`/`SandboxClaim`/`SandboxTemplate` CRDs + operator. Both substrates depend on these CRDs existing. |
| `1` | `argo-workflows` | The pipeline engine the Dark Factory examples submit to. |
| `1` | `argo-events` | Turns a GitHub webhook into a workflow submission. Needs its EventBus before Sensors work. |
| `2` | `bifrost` *(optional)* | In-cluster LLM gateway for the Kata agent, so model calls can be traced. |
| `2` | `otel-collector` *(optional)* | Traces/metrics pipeline. |
| `3` | `langfuse` *(optional)* | LLM tracing UI; consumes what the collector and gateway emit. |

Turn the optional ones off in your `values.yaml` — the blueprint works without them, you just lose
LLM tracing.

## Verify

```bash
task status                        # ArgoCD applications + sandbox objects
kubectl get applications -n argocd
kubectl get crd | grep agents.x-k8s.io
```

All Applications should reach `Synced / Healthy` before you install a substrate.
