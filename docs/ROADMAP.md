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

---

## Known gaps (as of the first verified end-to-end runs)

Everything below is **known and deliberate to defer**, not undiscovered. Both
substrates have produced reviewed, mergeable PRs with both AWS review agents gating.
These are the edges you will hit next.

### 1. No public webhook — runs are submitted directly

**Impact:** the "label a GitHub issue and walk away" experience is not live. Every run
in this repo was started by submitting a `Workflow` directly (see
[MANUAL-STEPS §2](MANUAL-STEPS.md), Option B).

**Why:** the EventSource needs a public address. Two things do not work as they appear:
`spec.service.type: LoadBalancer` on an EventSource is ignored by the Argo Events
controller (it always creates a ClusterIP), and a plain `LoadBalancer` Service does not
get an NLB on EKS 1.36 — in-tree cloud LoadBalancer support is gone, so it sits at
`EnsuringLoadBalancer` forever.

**Fix:** install the **AWS Load Balancer Controller** as a platform addon. The
`dark-factory-webhook` Service is already in the chart and will resolve once it exists.

### 2. Security Agent space IDs must be seeded by hand

OAP ships a PreSync Job that finds-or-creates the Agent Space and writes its IDs into a
Secret. This blueprint does not port it, so `securityAgent.secretName` must exist before
enabling the agent. Documented with the `kubectl` in [MANUAL-STEPS §5d](MANUAL-STEPS.md).

**Fix:** port that Job, or replace it with a Terraform-managed lookup.

### 3. `deploy-test` runs despite `enabled: false`

It is defaulted off in all three values trees (the blueprint ships no deploy-test image
and Terraform creates no ECR repo for one), yet it executed on a run and posted
`dark-factory/deploy-test`. Harmless when it passes; misleading when it fails. **Root
cause not established** — do not assume the flag works.

### 4. Lambda workflow reports Failed after a successful PR

`df-run-lambda` finished `Failed` with `provision-microvm` exiting 1, *after* the PR was
already built, reviewed and green. So **workflow phase ≠ PR outcome**, in both
directions (a Kata run reported `Succeeded` while its PR was blocked by an agent). Judge
a run by its PR checks, not its Argo phase. The failing tail is likely the
suspend/teardown step.

### 5. MicrovmImage names are scoped per cluster to avoid collisions

A `MicrovmImage` is account-scoped and the pre-GA `lambdamicrovms` ACK controller
**ignores adoption annotations** — it always calls `CreateMicrovmImage`, so an existing
name fails permanently with `ConflictException`. Worked around by keying the image,
bucket and roles to the cluster name. Revisit when the controller supports adoption, or
goes GA under Managed ACK.

### 6. The three example values trees are byte-identical duplicates

`examples/_shared/values.yaml` plus a `defaults.yaml` per example, because a subchart's
values are invisible to parent templates. `task lint:deps` and CI guard the drift, but
the real fix is moving each example's WorkflowTemplate into the shared subchart behind a
`substrate` value so there is one tree. The same split is why `task demo` must `--set`
every value at **both** scopes.

### 7. Values carry unused upstream keys

The trees were extracted wholesale from OAP and still contain keys this blueprint never
reads. They are harmless but make the surface look larger than it is.

### 8. Comment → `df-iterate` auto-trigger is unverified

Labelling an issue triggers a run end to end (proven on both substrates). Commenting on
a PR to request a fix does **not** — the sensor receives the webhook (GitHub reports
`200 OK`) and then discards it:

```
expr filter error (Cannot transition token types from
VARIABLE [body_comment_body] to VARIABLE [matches])
```

A filter that errors drops the event, so `submit-df-iterate` never fires.

**Do not fix this here in isolation.** The expression is byte-identical to OAP's
reference implementation, so a local change would fork a bug fix away from the
reference. Ruled out already: stale logs (a fresh pod reproduces it), stale JetStream
consumers (the Sensor was recreated), a drifted vendored subchart (source and `.tgz`
match), and the webhook not arriving. Removing the `matches` clause also did **not**
fix it.

**Likeliest cause:** the argo-events version. This blueprint pins `2.4.15`; expr-lang's
handling of `matches` changed across releases, so compare with the version OAP's hub
runs. Note that pre-fix deliveries replay from JetStream and log the same error, which
makes stale and live failures indistinguishable — separate them by event ID:

```bash
kubectl logs -n argo-events -l sensor-name=dark-factory --tail=200 \
  | grep -o 'Event \[ID .[a-f0-9]*.' | sort | uniq -c
```

**Workaround (proven):** submit `df-iterate` directly with the finding as
`comment-body`. That is how PR #149 went from DevOps-Agent-blocked to approved.
