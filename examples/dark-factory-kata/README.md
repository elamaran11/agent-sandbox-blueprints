# Dark Factory on Kata

An issue becomes a reviewed, merged PR — written by an agent inside a Kata micro-VM.

**Prerequisites:** `task up` (platform) and `task kata` (substrate) are done, and you
have a **throwaway** GitHub repo to point this at.

## 1. Configure

```bash
cp values.example.yaml values.yaml
```

Edit `values.yaml` — at minimum `github.repo` and `agent.image`
(`terraform output coder_ecr_urls` gives you the image URL).

## 2. Create the GitHub Secret and webhook

Follow [`../_shared/SECRETS.md`](../_shared/SECRETS.md). Two credentials: a
repo-scoped token and a webhook HMAC secret. Neither goes in `values.yaml`.

## 3. Build and push the agent image

```bash
aws ecr get-login-password --region us-west-2 \
  | docker login --username AWS --password-stdin <account>.dkr.ecr.us-west-2.amazonaws.com

docker build -t <account>.dkr.ecr.us-west-2.amazonaws.com/dark-factory-coder:v1 ../_shared/agent
docker push  <account>.dkr.ecr.us-west-2.amazonaws.com/dark-factory-coder:v1
```

## 4. Deploy the pipeline

```bash
task demo-kata
```

## 5. Run it

Create an issue in your target repo describing a small, self-contained change, then add
the trigger label (`dark-factory` by default).

Good first issue — concrete, testable, one file:

> **Title:** Add an SQS queue for async jobs
> **Body:** Add an Amazon SQS queue for asynchronous job processing plus a
> least-privilege EC2 IAM role allowed to send and receive on it. Put everything in a
> new file `infra/sqs.tf`. Use Terraform with the aws provider.

## What you should see

| Stage | Where to look | Roughly |
|---|---|---|
| Sandbox claimed from the warm pool | `kubectl get sandboxclaims,sandboxes -n agent-sandbox-system` | seconds |
| Agent clones, implements, tests, pushes | Argo UI, or `kubectl logs -n agent-sandbox-system <sandbox-pod>` | ~2 min |
| **PR opened** | the target repo | ~2 min in |
| Gates report (holdout, deploy test) | commit statuses on the PR | ~1 min |
| Consolidated verdict | a sticky comment on the PR | |
| You approve → merge + teardown | PR merged, sandbox released | |

```bash
task status                                        # claims, sandboxes, ArgoCD apps
kubectl get wf -n argo                             # pipeline runs
kubectl port-forward -n argo svc/argo-workflows-server 2746:2746   # then open :2746
```

## Requesting a fix

If a gate reports findings, comment on the PR describing what to change — the agent
revises the same branch (capped by `iterate.maxIterations`).

> Comment from a **different** GitHub account than the one that owns the token. The
> pipeline posts as the token owner, so it ignores its own voice — a comment from that
> same account looks like self-chatter and is skipped.

## Merging

Merge requires a **human approval event**. The gates are advisory signals; approving the
PR is what triggers merge and sandbox teardown.

## Wiring the AWS review agents (optional)

`gates.securityAgent` and `gates.devopsAgent` are **off by default** because they are
external GitHub Apps tied to specific AWS accounts — most people cannot install them, and
the blueprint should still work end to end.

If you do have them:

1. Install the App(s) on your target repository.
2. Set the corresponding `gates.*.enabled: true` in `values.yaml`.
3. Re-run `task demo-kata`.

The pipeline then waits for each App's verdict on the current commit and folds it into
the consolidated status. Two things to know from experience: each new commit restarts
those reviews (they take ~8–15 min), and their inline comments can carry forward onto
later commits, so judge a PR by the **commit statuses on the current head**, not by
comment count.

## Which hypervisor am I on?

`agent.runtimeClass` selects it — `kata-clh` by default. `kata-qemu` if you need GPU.
**`kata-fc` will not work for this agent**: Firecracker cannot mount volumes and the
agent needs a workspace. See [`../../kata/README.md`](../../kata/README.md).

## Cleaning up

```bash
kubectl delete sandboxclaims --all -n agent-sandbox-system   # release sandboxes
task down                                                   # destroy everything
```
