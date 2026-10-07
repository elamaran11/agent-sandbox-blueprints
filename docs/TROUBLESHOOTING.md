# Troubleshooting

Symptom → cause → fix, for the failures that actually happen. Ordered by layer.

## Platform

| Symptom | Cause | Fix |
|---|---|---|
| `terraform apply` fails enabling a capability | The ARGOCD/ACK/KRO capability is not available for your account or region | Set the matching `enable_managed_*=false` in `terraform.tfvars` and install the equivalent via Helm |
| ArgoCD Applications stuck `Missing`/`Unknown` | Root Application points at the wrong repo or revision | Check `gitops_repo_url` / `gitops_target_revision`; the repo must be reachable by ArgoCD |
| Your `values.yaml` changes have no effect | ArgoCD reads manifests from **git** — a gitignored values file is invisible to it | Terraform injects that file as inline values; re-run `task tf:apply` after editing it |
| Applying `bootstrap/` wipes your overrides | The static fallback manifest has no inline values | Don't apply it when Terraform manages the root app — `task gitops:bootstrap` already guards this |

## Kata

| Symptom | Cause | Fix |
|---|---|---|
| Kata pod stays `Pending`, no node appears | The RuntimeClass `nodeSelector` label doesn't exist on any node yet — Karpenter can't provision for it | The label must be set at **node birth** by the NodePool, not by kata-deploy after install (otherwise it deadlocks) |
| Node appears but pods never bind | The `katacontainers.io/runtime-not-ready` startup taint was never removed | The readiness DaemonSet removes it once kata-deploy's `/readyz` returns 200; check that DaemonSet's logs |
| `helm template kata/kata-deploy` renders nothing | Un-vendored OCI chart dependency | `helm dependency build kata/kata-deploy` — ArgoCD resolves this itself in-cluster |
| Pod fails to start under `kata-fc` | Firecracker has no `virtio-fs`, so it **cannot mount volumes** | Use `kata-clh` or `kata-qemu` for anything needing a workspace |
| GPU not visible in the sandbox | Only QEMU does VFIO passthrough | Use `kata-qemu`, on a GPU family that also exposes nested virtualization |
| Nested-virt capacity errors | Family/region shortage | Use the bare-metal fallback NodePool |

## Lambda MicroVM

| Symptom | Cause | Fix |
|---|---|---|
| VM shows `RUNNING` when it should be suspended | Something touched the VM endpoint (e.g. a log-tail loop) and auto-resumed it | `idlePolicy.autoResumeEnabled: false` **and** stop polling the endpoint after suspend |
| CR says `RUNNING` but AWS says otherwise | `Microvm.status.state` is **stale** — it does not track suspend/resume/terminate | Always trust `aws lambda-microvms get-microvm --query state` |
| Resume fails: *"has been terminated and its state cannot be changed"* | The suspended VM was auto-terminated before the fix round | Raise `suspendedDurationSeconds` (max `28800` = 8 h) |
| Resume fails with an internal service error, VM dies | Pre-GA flakiness in resume-from-suspend | Detect real state and **recreate** rather than assume resume works |
| Image edits have no effect | Overwriting the **same** S3 key does not rebuild | Publish under a new key and bump `codeArtifactUri` |
| Agent crashes instantly with `EACCES` on its workspace | Read-only rootfs, no volume mount | `WORKSPACE=/tmp/workspace` |
| Cannot mint an auth token | `ALL_INGRESS` blocks token minting | Use `HTTP_INGRESS` |
| Agent can't reach the LLM gateway | The VM is outside the cluster network | Bedrock-direct via the execution role |
| KRO graph stuck `Inactive` (cache sync timeout) | Managed KRO only watches the **`kro.run`** API group | The RGD's `schema.group` must be `kro.run` |
| suspend/resume flapping until the VM dies | Two owners pointing at one VM with conflicting intent | One VM per unit of work; key the CR name to the issue |

## AgentCore Runtime

| Symptom | Cause | Fix |
|---|---|---|
| KRO graph rejects resource id `runtime` | KRO reserves that id | Use `agentRuntime` as the child resource id |
| ACK `AgentRuntime` does not reconcile | Managed ACK bundles the `bedrockagentcorecontrol` controller | Confirm its CRD is installed; do not install a second controller or add a controller IAM role |
| `AgentRuntime` reports AccessDenied on `CreateAgentRuntime` or `CreateAgentRuntimeEndpoint` | Managed ACK capability role lacks the named action | Check the `AgentCoreRuntimes` statement in `infrastructure/terraform/capabilities.tf`; use the named denied action to diagnose |
| `CreateAgentRuntime` fails on `TagResource` for a workload identity | The service creates an identity in the default directory outside the runtime ARN | Check `AgentCoreWorkloadIdentity` in `infrastructure/terraform/capabilities.tf` |
| AWS returns `ConflictException` after deleting a CR mid-reconcile | The runtime remains in AWS without its KRO/ACK owner | Delete the **orphaned AWS runtime** by CLI and wait for AWS deletion to finish before retrying; never delete the `AgentRuntime` or `AgentCoreSandbox` CR mid-reconcile |
| Workflow waits 15 minutes after a successful PR, then reports `Failed` | `review.enabled=true` adds review DAG tasks even when both review App flags are off | Set `review.enabled=false` in the local values at both scopes until the Apps are installed; read PR head statuses separately |
| `bedrock-agentcore list-sessions` does not show runtime sessions | This command is for the AgentCore Memory API, not a Runtime inventory | Read workflow logs and stop result; query runtime state with `bedrock-agentcore-control get-agent-runtime` |
| `invoke-agent-runtime` returns 409 | A coder is already running in that session; the host permits one coder per session | Check the old workflow/session, stop it if its result is ambiguous, then invoke with a **new** workflow UID/session ID |
| V2 runtime never reaches `READY` | Container did not answer `GET /ping` within 120 seconds, or snapshot preparation failed | Inspect `/aws/bedrock-agentcore/runtimes/` in CloudWatch; confirm the arm64 host binds `0.0.0.0:8080` and answers `Healthy` at startup |
| `update-agent-runtime` returns `ConflictException` | A prior create/update/delete is still in progress | Poll `aws bedrock-agentcore-control get-agent-runtime --agent-runtime-id <id> --query status`; retry only in a terminal state (`READY` or a `*FAILED` status), and investigate failure before retrying |
| VPC mode fails to reach READY | The failing reason is not established from status alone | Read the AWS runtime failure reason and check subnet AZ support, egress, and security group before retrying |
| `task agentcore` reports READY/V2 but the requested VPC mode is absent | ArgoCD applies the Application asynchronously; an old sync can keep the prior mode until ACK reconciles | Wait for AWS READY with the requested network mode, subnet IDs, and security group; the verified PUBLIC→VPC switch took about 9.5 minutes. Inspect ArgoCD's operation rather than deleting an `AgentRuntime` or `AgentCoreSandbox` CR |
| Terraform stays `Still destroying...` on the AgentCore security group after switching back to PUBLIC | Three `agentic_ai` ENIs remained attached in the live run, even after deleting the unused VPC runtime version | Verify the DEFAULT endpoint uses the new PUBLIC version. Check ENIs by security group with `aws ec2 describe-network-interfaces --filters Name=group-id,Values=<sg-id>`. Do not manually detach AWS-managed ENIs; [AWS says they may persist up to eight hours](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/agentcore-vpc.html). Keep the security group in Terraform state and retry the targeted apply after the ENIs disappear |

## Pipeline

| Symptom | Cause | Fix |
|---|---|---|
| Webhook arrives, no Workflow created | Sensor has stale JetStream consumers after an EventBus restart | Delete the stale consumers and restart the sensor |
| PR comment is ignored after `df-iterate` starts | With `iterate.identityGuard=true`, a PAT shared with the repo owner makes human comments look like the factory's own comments | Use a separate factory identity or disable the guard when the token identity is shared; check the Sensor filter first if no `df-iterate` starts |
| PR comment arrives but no `df-iterate` workflow appears | Argo Events Sensor rejects the `matches` expression with `Cannot transition token types from VARIABLE [body_comment_body] to VARIABLE [matches]` | See [ROADMAP gap #8](ROADMAP.md); submit `df-iterate` directly with the posted comment while the Sensor filter remains broken |
| Merge refused despite green checks | Stale findings from an earlier commit being counted | Judge by commit statuses on the **current head**; inline comments carry forward |
| Agent re-ran but committed nothing | The review note never reached the sandbox | The note must ride in the sandbox's injected env / run payload |
| Reviews restart on every push | Each new commit re-triggers the external agents (8–15 min each) | Expected; batch fixes into one commit where you can |
| Runs pile up and stall | Concurrency is bounded by the warm pool; extra runs wait for a free sandbox | Raise `agent.warmPoolSize`, or accept the queue |

## Cost / leak checks

```bash
# MicroVMs still alive (should be empty when idle) — a leaked VM is a running bill
aws lambda-microvms list-microvms --region us-west-2 \
  --query "items[?state!='TERMINATED'].[microvmId,state]" --output table

kubectl get sandboxclaims,sandboxes -A      # orphaned sandboxes hold Kata nodes up
kubectl get nodes -l kata-enabled=true      # should scale to zero when idle
```

If `task down` fails partway, re-run it — it deletes sandboxes and `Microvm` CRs before
destroying the cluster so substrate controllers can terminate remote VMs first.

## ExternalSecret stuck: "could not get secret data from provider"

Check the controller log. If the AccessDenied names the **node** role
(`.../system-eks-node-group-.../i-0e...`) rather than `<cluster>-external-secrets`,
the IAM policy is fine — the pod is simply older than its Pod Identity association.
Pod Identity credentials are injected at pod admission, so a pod that was already
running never gets them and silently falls back to the node role.

```bash
kubectl rollout restart deploy/external-secrets -n external-secrets
# then confirm the creds are present:
kubectl get pod -n external-secrets -l app.kubernetes.io/name=external-secrets \
  -o jsonpath='{.items[0].spec.containers[0].env[*].name}' | tr ' ' '\n' | grep AWS_CONTAINER
```

Expect `AWS_CONTAINER_CREDENTIALS_FULL_URI` and
`AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE`. If they are absent, the pod predates the
association. This applies to ANY Pod Identity consumer, not just ESO.
