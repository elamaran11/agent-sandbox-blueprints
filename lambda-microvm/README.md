# AWS Lambda MicroVM substrate

Runs each agent sandbox as a **serverless Firecracker MicroVM** that AWS provisions on
demand, **suspends while idle**, and terminates when the work is merged. No node pool.

> **Preview service.** The `lambdamicrovms` API is pre-GA (`v1alpha1`). Expect API
> changes and occasional control-plane flakiness. Pilot-grade, not production.

```bash
task lambda    # installs everything in this folder
```

## Why this substrate exists

The agent is bursty: it thinks hard for two minutes, then waits ten for a human or a
reviewer. Kata keeps a node pool running through all of that. Lambda MicroVM
**suspends the VM between rounds**, so you pay for the minutes the agent is actually
working. That is the entire value proposition — not latency (it is *slower* to start),
but economics and having no fleet to operate.

## What gets installed

| Piece | What it does |
|---|---|
| `bootstrap/00-ack-controller.yaml` | The **self-managed** `lambdamicrovms` ACK controller — the only controller this blueprint runs itself |
| `templates/kro-rgd/` | A KRO `ResourceGraphDefinition` composing the MicroVM image + IAM roles + S3 bucket into one CRD, and the single platform image instance |
| `templates/shim-bridge/` | The `SandboxTemplate` whose pod bridges a `SandboxClaim` to a remote MicroVM, plus the controller that turns `Sandbox.operatingMode` into suspend/resume |
| `templates/iam/` | Pod Identity associations for the controller, bridge, and lifecycle controller; RBAC for KRO's identity over the ACK children it creates |
| `image/` | `hook-server.js` + `Dockerfile` + `publish.sh` — the same agent, wrapped for the MicroVM snapshot/hook runtime |

## Managed vs self-managed

This is the one place the blueprint runs an AWS controller itself, and it is forced:

| Controller | How | Why |
|---|---|---|
| ACK `iam`, `s3` | **Managed ACK capability** | GA services — AWS runs them |
| KRO | **Managed KRO capability** | AWS runs it |
| ACK `lambdamicrovms` | **Self-managed** (OCI chart, pinned `0.1.1`) | Pre-GA, so Managed ACK does not bundle it |

They coexist — different CRD groups, no conflict. **When `lambdamicrovms` goes GA:
delete the self-managed Application and Managed ACK adopts it. The KRO graph does not
change.**

⚠️ **Managed KRO only watches the `kro.run` API group.** A `ResourceGraphDefinition`
declaring any other `schema.group` never leaves `state=Inactive` with a cache-sync
timeout. That is why the graph here uses `kro.run`.

## Setup

### 1. Build and publish the agent artifact

Lambda MicroVM does not take a container image reference — it builds the VM image from
a **ZIP in S3** whose Dockerfile pulls the agent image from ECR as a base layer.

```bash
# ARM64 only — Lambda MicroVM does not run x86_64
docker buildx build --platform linux/arm64 \
  -t <acct>.dkr.ecr.us-west-2.amazonaws.com/dark-factory-coder-microvm:v1-arm64 \
  --push examples/dark-factory-lambda/agent

./image/publish.sh r1        # zips Dockerfile + hook-server + agent → S3
```

### 2. Point the substrate at that artifact

Set `codeArtifactUri` to the key `publish.sh` printed. **Every publish needs a new
key** — overwriting the same key does *not* rebuild the image.

### 3. Watch the image build

```bash
kubectl get microvmimage -A -w
```

## Lifecycle

```
provision  create Microvm CR  → ACK RunMicrovm → VM boots hook-server
drive      mint auth token    → POST /run      → agent works, opens a PR
suspend    suspend-microvm    → VM SUSPENDED   → free while reviewers/humans look
resume     resume-microvm     → same VM back   → agent applies review fixes
teardown   delete Microvm CR  → TerminateMicrovm
```

## Operational notes that will save you hours

These are all things that actually bit during development.

**Suspend only sticks if nothing touches the VM.**
`idlePolicy.autoResumeEnabled` must be `false`, **and** nothing may hit the VM
endpoint after suspending. Any inbound request auto-resumes it. A log-tailing loop
against the endpoint will silently keep the VM awake forever.

**Do not trust the CR status.** `Microvm.status.state` is **stale** — it does not
reflect suspend/resume/terminate. Always read AWS:
```bash
aws lambda-microvms get-microvm --microvm-identifier <id> --query state --output text
```

**Suspend has an 8-hour ceiling.** `suspendedDurationSeconds` max is `28800`. Past it,
the VM is auto-terminated. Set it too low (say 5 minutes) and the VM is gone before a
human ever posts review feedback, so resume fails with *"has been terminated and its
state cannot be changed."*

**Resume is occasionally flaky.** Pre-GA: `resume-microvm` sometimes fails with an
internal service error and terminates the VM. Handle it by checking real state and
**recreating** when resume is impossible, rather than assuming resume works.

**One VM per session.** If two owners point at the same MicroVM with conflicting
intents, suspend and resume fight until the VM dies. Key the CR name to the unit of
work (one issue → one VM).

**The rootfs is read-only.** Only `/tmp` is writable and there is no volume mount, so
the agent must use `WORKSPACE=/tmp/workspace`. Pointing it at `/workspace` fails with
`EACCES` before doing any work.

**No cluster networking.** The VM is outside the VPC, so it cannot reach an in-cluster
LLM gateway. It calls **Bedrock directly** via its execution role.

**`/run` has a 30-second timeout.** The agent runs for minutes, so `/run`
background-spawns it and returns immediately; the pipeline polls GitHub for the PR.

**Use `HTTP_INGRESS`.** `ALL_INGRESS` prevents minting an auth token, so the bridge
cannot drive the VM.

## Verify

```bash
kubectl get microvmsandbox -A                      # KRO graph instance
kubectl get microvmimage -A                        # platform image build
kubectl get crd | grep lambdamicrovms              # ACK CRDs registered

# AWS is the source of truth for VM state
aws lambda-microvms list-microvms --region us-west-2 \
  --query "items[?state!='TERMINATED'].[microvmId,state]" --output table
```

That last command is also your **cost check** — a leaked non-terminated VM is a
running bill. `task down` deletes the `Microvm` CRs before destroying the cluster for
exactly this reason.

## Next

Run the agent on this substrate:
[`examples/dark-factory-lambda`](../examples/dark-factory-lambda/README.md)
