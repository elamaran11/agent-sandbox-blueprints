# Dark Factory on Amazon Bedrock AgentCore Runtime

The shared coder runs in a disposable AgentCore Runtime session for each coding
round. GitHub stores the branch and review feedback between rounds. For runtime
setup, the HTTP host contract, V2 behavior, and network modes, see the
[substrate README](../../agentcore/README.md).

## Set up

Prerequisites: `task up`, a published ARM64 coder image, `task agentcore`, and a
throwaway GitHub repository. Run commands from the repository root.

```bash
cp examples/dark-factory-agentcore/values.example.yaml examples/dark-factory-agentcore/values.yaml
# Edit trigger.argoEvents.repositories, webhookUrl, and agentcore.region.
task demo-agentcore
```

`task demo-agentcore` injects `agentcore.sandboxName` from
`AGENTCORE_SANDBOX` (default `coder`), along with the cluster name and images.
Overrides to shared settings such as `trigger`, `github`, `iterate`, and review
must appear both at the top level and under `dark-factory-shared:`. Do not disable
`microvm.enabled` at the shared scope: every example manages the same workflow
Role, and Lambda needs its MicroVM permissions.

Create the GitHub token Secret and webhook as described in
[`../_shared/SECRETS.md`](../_shared/SECRETS.md). Keep credentials out of git.
The Sensor routes the `darkfactory-agentcore` issue label to this workflow.
If the AWS review Apps are not installed, set `review.enabled: false` in the
local, gitignored `values.yaml` at both scopes. Disabling only
`devopsAgent.enabled` or `securityAgent.enabled` does not remove the review DAG
steps.

## Run and inspect

Label a small, testable issue `darkfactory-agentcore`. The Sensor submits
`df-run-agentcore-<issue-number>`. The workflow invokes a session using its UID,
then `await-coder` waits for a PR and a successful `dark-factory/implementation`
commit status. Session stop and the enabled gates both depend on `drive-coder`:
they run in parallel. `teardown` repeats the stop on success or failure. The
runtime stays available for another session.

```bash
kubectl get wf -n argo
kubectl get agentcoresandbox coder -n agent-sandbox-system -o yaml
ID=$(kubectl get agentcoresandbox coder -n agent-sandbox-system -o jsonpath='{.status.runtimeID}')
aws bedrock-agentcore-control get-agent-runtime --region us-west-2 --agent-runtime-id "$ID"
```

Use `get-agent-runtime` for runtime status and `kubectl` plus workflow logs for
invocation and stop results. `bedrock-agentcore list-sessions` is a Memory API,
not a Runtime session inventory. Do not delete the `AgentRuntime` or
`AgentCoreSandbox` CR to stop a session: an in-progress ACK reconciliation can
leave an orphaned AWS runtime.

## Request a fix

Post a review comment on the PR. `df-iterate` reads the original issue label
and submits `df-run-agentcore-<issue-number>-i<round>`. The coder checks out the
existing `df/issue-N` branch in a new session; the workflow waits for a **new**
head SHA before judging the fix. Keep the issue label. `review.autoFixFindings`
must stay off; request fixes through the human-driven path. See
[ROADMAP gap #8](../../docs/ROADMAP.md) for the webhook filter status.

## Cleanup

An ended coder session can already be stopped; a failed stop remains advisory.
If a stop fails, inspect its CLI error and use the workflow UID explicitly:

```bash
ARN=$(kubectl get agentcoresandbox coder -n agent-sandbox-system -o jsonpath='{.status.runtimeARN}')
SESSION=$(kubectl get wf <workflow-name> -n argo -o jsonpath='{.metadata.uid}')
aws bedrock-agentcore stop-runtime-session --region us-west-2 \
  --agent-runtime-arn "$ARN" --runtime-session-id "$SESSION"
```

For observed reconciliation, permissions, VPC, and review failures, see
[`docs/TROUBLESHOOTING.md`](../../docs/TROUBLESHOOTING.md).
