# Roadmap and known limitations

This is a **blueprint**: it demonstrates the pattern end to end with the fewest moving
parts. It is not a hardened product. Here is what that honestly means.

## Known limitations

### No real backpressure
Concurrency is bounded only by the sandbox warm-pool size (Kata) or AWS MicroVM quotas
(Lambda). There is a per-issue mutex preventing duplicate runs of the same issue, but
nothing across issues: label 50 issues and you get 50 workflows, with the excess waiting
for a free sandbox rather than being queued fairly.

**What production needs:** an Argo `semaphore` (ConfigMap-backed) to admit *N* and hold
the rest in a real FIFO, keyed per repo/team for fairness, plus workflow `priority`.

### Single-tenant
One namespace, one workflow ServiceAccount, one warm pool, no per-team quotas or
isolation. Fine for one team demonstrating the pattern; not multi-tenant.

### One repository, one token
A single fine-grained PAT. At scale this becomes the bottleneck and the risk: one shared
rate limit across every agent and gate, and no per-repo authorization.

**What production needs:** a **GitHub App** — per-installation tokens, per-repository
permissions, independent rate limits. The manifests only require a usable `token`, so
this is a credential swap, not a pipeline change.

### External review agents are not reproducible
The AWS Security and DevOps reviewers are GitHub Apps tied to specific accounts, so they
are off by default. The default gate set (hidden-scenario holdout + deploy test) works for
everyone, but it is a weaker signal than a real security review.

### Lambda MicroVM is pre-GA
Expect API changes. Resume-from-suspend is intermittently flaky and occasionally
terminates the VM; the substrate handles this by recreating, which costs a cold start.
Do not build a product on this substrate yet.

### Kata has no true suspend/resume
`Sandbox.operatingMode: Suspended` deletes the pod and retains the volume — a **cold
restart with files intact**, the same model Coder and Gitpod use for Kubernetes
workspaces. It is *not* VM hibernation; in-memory state is lost. Upstream Kata work on
real save/restore is in progress. Only Lambda MicroVM offers warm suspend/resume here.

### Firecracker cannot run this agent
No `virtio-fs`, so no volume sharing, and the agent needs a workspace. `kata-fc` is
installed and usable for stateless workloads, but not for the Dark Factory pipeline.

## Natural next steps

| Idea | Why it matters |
|---|---|
| Argo `semaphore` + per-repo keys | Turns implicit pool-starvation into real, fair, observable queuing |
| GitHub App auth | The unlock for many repositories |
| In-workflow retry for MicroVM resume | A single flaky resume currently ends that round; retry would self-heal in place |
| Pluggable gate interface | Let people drop in their own reviewers instead of hardcoded ones |
| Long-lived workspaces (remote IDE) | The Kata substrate + a persistent volume is most of a Coder/Gitpod-style dev environment; `code-server` in the sandbox is a small step |
| GPU sandboxes | `kata-qemu` + VFIO on a nested-virt GPU family, for agents that need inference locally |
| Cost reporting per run | Attribute Bedrock tokens + compute minutes to a PR, so the economics are visible |

## Non-goals

Kept out on purpose, because they obscure the pattern:

- Multi-cluster / hub-spoke fleet management
- A large addon catalog (service mesh, portals, alternative gateways)
- Production hardening: HA NAT, private-only endpoints, org SCPs, audit pipelines
