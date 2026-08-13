# Dark Factory on AWS Lambda MicroVM

The same pipeline as the Kata example, with the agent running in a **serverless
Firecracker MicroVM** that is **suspended while humans and reviewers look at the PR**.

**Prerequisites:** `task up` and `task lambda` are done, and you have a **throwaway**
GitHub repo.

> **Preview service.** `lambdamicrovms` is pre-GA. Expect occasional control-plane
> flakiness — notably resume-from-suspend. See [Troubleshooting](#troubleshooting).

## 1. Configure

```bash
cp values.example.yaml values.yaml
```

Edit `github.repo`, `microvm.baseImage`, and `microvm.codeArtifactUri`.

## 2. Create the GitHub Secret and webhook

Follow [`../_shared/SECRETS.md`](../_shared/SECRETS.md) — same two credentials as the
Kata example. Use a **different** `github.triggerLabel` (default
`darkfactory-lambda`) so both substrates can coexist on one cluster.

## 3. Build the ARM64 agent image and publish the artifact

Lambda MicroVM is **ARM64-only**, and it builds the VM image from a **ZIP in S3** rather
than pulling a container image directly.

```bash
# ARM64 base image (pulled as a layer by the artifact's Dockerfile)
docker buildx build --platform linux/arm64 \
  -t <account>.dkr.ecr.us-west-2.amazonaws.com/dark-factory-coder-microvm:v1-arm64 \
  --push ../_shared/agent

# Zip Dockerfile + hook-server + agent, upload under a NEW versioned key
../../lambda-microvm/image/publish.sh r1
```

Copy the `codeArtifactUri` it prints into `values.yaml`.

> **Every publish needs a new key.** Overwriting the same S3 key does *not* rebuild the
> image — the build is triggered by `codeArtifact.uri` *changing*. This is the single
> most common "my fix didn't take effect" mistake here.

## 4. Deploy the pipeline

```bash
task demo-lambda
```

## 5. Run it

Label an issue with `darkfactory-lambda`. Same kind of issue as the Kata example works
well — one small, self-contained, testable change.

## What you should see

The interesting part is the VM lifecycle:

| Stage | What happens | Roughly |
|---|---|---|
| Provision | `Microvm` CR created → `RunMicrovm` → VM boots the hook-server | ~90 s cold start |
| Drive | Auth token minted, `POST /run`, agent works | |
| **PR opened** | | ~2.5 min in |
| **Suspend** | VM suspended — **you stop paying for compute while reviewers run** | seconds |
| Gates | holdout + deploy test report on the PR | ~1 min |
| Fix round | VM **resumed** (same VM, memory intact) → agent revises | |
| Merge | You approve → merge → `Microvm` CR deleted → VM **terminated** | |

Watch the VM directly — **AWS is the source of truth**, the CR status is stale:

```bash
kubectl get microvm -A                       # the CR (status.state is NOT reliable)

aws lambda-microvms list-microvms --region us-west-2 \
  --query "items[?state!='TERMINATED'].[microvmId,state]" --output table
```

Seeing `SUSPENDED` there while the PR sits in review is the whole point of this
substrate.

## Requesting a fix

Comment on the PR (from a **different** account than the token owner — the pipeline
posts as that identity and ignores itself). The fix round resumes the same suspended VM.

If resume fails because the pre-GA service terminated the VM, the pipeline provisions a
fresh one instead of dead-ending — you will see a cold start rather than a resume.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| VM shows `RUNNING` when it should be suspended | Something is hitting the VM endpoint (a log-tail loop), which auto-resumes it | Ensure `idlePolicy.autoResumeEnabled: false` and nothing polls the endpoint after suspend |
| Resume fails: *"has been terminated and its state cannot be changed"* | The VM was auto-terminated before the fix round | Raise `suspendedDurationSeconds` (max `28800` = 8 h) |
| Agent re-ran but committed nothing | The review note never reached the VM | The note rides in the `runHookPayload`; a resumed VM must also accept a *new* `/run` |
| Image changes have no effect | Reused the same S3 key | Publish under a **new** key and bump `codeArtifactUri` |
| Agent crashes immediately with `EACCES` | Rootfs is read-only | Workspace must be `/tmp/workspace` |

More detail: [`../../lambda-microvm/README.md`](../../lambda-microvm/README.md).

## Cost check

A non-terminated MicroVM is a running bill. Before you walk away:

```bash
aws lambda-microvms list-microvms --region us-west-2 \
  --query "items[?state!='TERMINATED']" --output table   # should be empty

task down     # deletes Microvm CRs first, then the cluster
```
