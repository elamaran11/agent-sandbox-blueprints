# Dark Factory on Nitro Sandbox

The same pipeline as the Kata example, with the agent running in its **own Nitro-isolated
microVM** on an EKS Auto Mode node. No nested virtualization, and no runtime installed on
the node.

**Prerequisites:** `task up` with `enable_auto_mode = true`, then `task nitro` (see
[`../../nitro-sandbox/README.md`](../../nitro-sandbox/README.md)), and a **throwaway**
GitHub repo to point this at.

> **Private preview.** EKS Pod Isolation is not generally available, and your account
> must be enabled for it. Names, annotations and numbers can change before launch.

## 1. Configure

```bash
cp values.example.yaml values.yaml
```

Same keys as the Kata example. At minimum, set `trigger.argoEvents.repositories` to the
repo the agent works in.

## 2. Create the GitHub Secret and webhook

Follow [`../_shared/SECRETS.md`](../_shared/SECRETS.md). Same two credentials as the Kata
example, and if you already created them for Kata, they are shared.

## 3. Build and push the agent image

The Nitro coder runs the **same amd64 image** as the Kata coder, `dark-factory-coder`.
If you built it for Kata, skip this.

```bash
aws ecr get-login-password --region us-west-2 \
  | docker login --username AWS --password-stdin <account>.dkr.ecr.us-west-2.amazonaws.com

docker build --platform linux/amd64 -t <account>.dkr.ecr.us-west-2.amazonaws.com/agent-sandbox/dark-factory-coder:latest ../_shared/agent
docker push  <account>.dkr.ecr.us-west-2.amazonaws.com/agent-sandbox/dark-factory-coder:latest
```

`task nitro` points the coder template at this repo and tag (`terraform output
coder_ecr_urls`, tag `latest`). If you set `warmPool.targetIdle` to `1`, a spare
that came up before the push sits in `ImagePullBackOff` and recovers on its own
once the image exists.

## 4. Deploy the pipeline

```bash
task demo-nitro
```

## 5. Run it

Create an issue describing a small, self-contained change, and add the label
**`darkfactory-nitro`**. The Kata example's sample issue works here too.

The label is the only thing that picks the substrate. One cluster can run all three
examples side by side for different issues: `dark-factory` goes to Kata,
`darkfactory-lambda` to Lambda MicroVM, `darkfactory-nitro` here. Give each issue one
substrate label. Every substrate works on the same `df/issue-<n>` branch and PR, so a
second run on an issue that already has a PR picks up the first run's commit as its own.

## What you should see

| Stage | Where to look | Roughly |
|---|---|---|
| Sandbox claimed, coder microVM boots | `kubectl get sandboxclaims,sandboxes -n agent-sandbox-system` | seconds on a node that holds the image |
| Agent clones, implements, tests, pushes | Argo UI, or `kubectl logs -n agent-sandbox-system df-nitro-<issue-id>` | as on Kata |
| **PR opened** | the target repo | |
| Gates report, consolidated verdict | commit statuses and a sticky comment on the PR | as on Kata |
| You approve → merge + teardown | PR merged, claim deleted | |

```bash
task status                                        # claims, sandboxes, ArgoCD apps
kubectl get wf -n argo                             # pipeline runs
kubectl port-forward -n argo svc/argo-workflows-server 2746:2746   # then open :2746
```

Measured on 2026-10-05, the coder's container started about 4 seconds after the claim
was scheduled on a node that already had the image. The first coder on a node took 27
seconds, mostly pulling and converting the 1 GB image. With no sandbox node up, Auto Mode
launches one first, which took about 45 seconds from apply to a running pod with a small
image.

What has been validated on Nitro is the substrate end of the run: the claim, the coder's
microVM boot with its env, token and egress, and its first call to the GitHub API. A full
issue-to-merged-PR run on this substrate has not been recorded yet. Everything after the
claim is the Kata pipeline unchanged, so the later rows above are the Kata behavior.

## Requesting a fix

Comment on the PR describing the change, from a **different** GitHub account than the one
that owns the token (the pipeline ignores its own voice). `df-iterate` reads the original
issue's label and sends the round back to `df-run-nitro`, so the fix also runs on Nitro.
Keep `darkfactory-nitro` on the issue: without it, a fix round falls back to Kata.

## Merging

Same as Kata: a human approval event is the only thing that merges, and it also deletes
the sandbox claim.

## How this differs from the Kata run

| | Kata | Nitro Sandbox |
|---|---|---|
| WorkflowTemplate | `df-run` | `df-run-nitro` (same steps, different claim) |
| Isolation | Kata micro-VM on a nested-virt node | Nitro-isolated microVM on an Auto Mode node |
| Nodes | Karpenter `kata-nested` / `kata-metal` | Auto Mode `nitro-sandbox` NodePool, `m7i.xlarge` / `m8i.xlarge` |
| Warm pool | `coder-warmpool` | `coder-warmpool-nitro` |
| Claim | `df-issue-<id>` | `df-nitro-<id>` (the branch and PR are still shared: one substrate label per issue) |
| Coder resources | requests 1 CPU / 2Gi, limits 2 CPU / 4Gi | requests 1 CPU / 4Gi, which is the VM's real size |
| Coder egress | agent-sandbox's default policy | an explicit list: cluster DNS, Bifrost, public internet |

Both egress rows apply only on a cluster that enforces NetworkPolicy, and this blueprint
leaves enforcement off ([ROADMAP #10](../../docs/ROADMAP.md#10-agent-sandboxs-default-networkpolicy-blocks-bifrost-where-policy-is-enforced)).
`task nitro` tells you which kind of cluster you have.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `task nitro` says no Auto Mode node role | Terraform ran without Auto Mode | `enable_auto_mode = true` in `terraform.tfvars`, then `task tf:apply` |
| Coder `Pending` with `Insufficient cpu` or `Insufficient eks.amazonaws.com/nitro-sandbox` | The node is full (three coders per `m7i.xlarge` at `cpu: "1"`) | Auto Mode adds a node within a minute or so; if it does not, check the `nitro-sandbox` NodePool's `cpuLimit` |
| Coder stuck in `ContainerCreating`, events show `No space left on device` | An older node image that boots fewer microVMs than it advertises | Delete idle sandboxes, or replace the node |
| Coder cannot reach the LLM gateway | Bifrost is not where the coder's egress list expects it | The list allows pods labelled `app.kubernetes.io/name: bifrost` in namespace `bifrost` on port 8080; match `coderTemplate.networkPolicy` in `nitro-sandbox/sandbox-templates/values.yaml` to your platform values |
| Fix comment does nothing | Known pipeline gap: the sensor drops PR-comment events with an `expr filter error`, on every substrate ([ROADMAP §8](../../docs/ROADMAP.md#8-comment--df-iterate-auto-trigger-is-unverified)). Or the comment came from the token owner's account | Submit `df-iterate` directly with the comment as `comment-body`, as ROADMAP §8 describes; comment from a different account |

More detail: [`../../nitro-sandbox/README.md`](../../nitro-sandbox/README.md).

## Cleaning up

```bash
kubectl delete sandboxclaims --all -n agent-sandbox-system   # release sandboxes
task down                                                   # destroy everything
```
