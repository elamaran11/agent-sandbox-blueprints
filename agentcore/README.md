# Amazon Bedrock AgentCore Runtime substrate

Runs the shared dark-factory coder in a disposable AgentCore Runtime session.
The same `entrypoint.js` clones the issue branch, runs the coder, and opens a PR.
The workflow starts each round with `InvokeAgentRuntime`; session stop and review
gates both start after the coder finishes. Fix rounds use new sessions, not suspend.

## What gets installed

| Piece | Purpose |
|---|---|
| `bootstrap/10-substrate.yaml` | ArgoCD app for this opt-in Helm chart |
| `templates/iam/` | ACK role and Pod Identity for the separate Argo invoker SA; KRO child-resource RBAC |
| `templates/kro-rgd/` | One `AgentCoreSandbox` CRD and platform instance, composed of an ACK execution role and AgentRuntime |
| `image/` | arm64 coder image wrapper: `/ping` health and `/invocations` launch |

Managed KRO watches the `kro.run` API group. Managed ACK reconciles everything here: its `iam`
and `eks` controllers create the roles and Pod Identity, and its bundled
`bedrockagentcorecontrol` controller creates the `AgentRuntime`. This substrate
installs NO controller of its own. The ACK capability role must be allowed the
`bedrock-agentcore:*AgentRuntime*` actions; `infrastructure/terraform/capabilities.tf`
grants them (verified live: without the grant the AgentRuntime sits
`ACK.Recoverable` with `not authorized to perform: bedrock-agentcore:CreateAgentRuntime`).

## Prerequisites and image

Confirm that your account/region has AgentCore Runtime enabled and that the
Managed ACK capability on the cluster ships the `bedrockagentcorecontrol` CRDs
(`kubectl get crd agentruntimes.bedrockagentcorecontrol.services.k8s.aws`). Build the shared coder image
for **linux/arm64** before building this wrapper. AgentCore V2 is available in
`us-east-1`, `us-east-2`, `us-west-2`, `eu-west-1`, and `ap-northeast-1`.

`task agentcore` does this for you (it runs `task agentcore-image` when
`AGENTCORE_IMAGE` is unset and records the digest in `agentcore/.image-uri`).
By hand:

```bash
cd agentcore/image
REGION=us-west-2 \
  IMAGE_NAME=<account>.dkr.ecr.us-west-2.amazonaws.com/<repository> \
  CODER_IMAGE=<arm64-coder-image-uri> ./publish.sh r1
# Copy the printed repo@sha256:... URI to agentcore.image.uri.
```

The Dockerfile has no default base image: pass `CODER_IMAGE` explicitly. The
publisher logs in to ECR, pushes `agentcore-<revision>`, then prints the ECR
digest URI. The runtime uses the digest, not a mutable tag. Set `accountId`,
`podIdentity.clusterName`, `image.uri`, and `invoker.argoNamespace` before
syncing. The Taskfile substitutes these in `bootstrap/10-substrate.yaml`; it
also supplies `AGENTCORE_NETWORK_MODE`, `AGENTCORE_SUBNETS`, and
`AGENTCORE_SECURITY_GROUPS` (`[]` in PUBLIC mode).

`PUBLIC` uses outbound internet access. For `VPC`, supply **private** subnet
IDs in AgentCore-supported Availability Zones and the egress-only security
group from Terraform; confirm the AZs are supported in the target region before
deployment. The KRO graph includes `networkModeConfig` only in VPC mode.
Bedrock inference is direct through the runtime execution role in both modes.
In `us-west-2`, the supported AZ IDs are `usw2-az1`, `usw2-az2`, and
`usw2-az3` (all three were used in the live VPC run). AgentCore creates ENIs
through `AWSServiceRoleForBedrockAgentCoreNetwork`; the execution role needs no
EC2 network-interface permissions. Private subnets need a NAT route for GitHub,
Bedrock, and ECR access in this blueprint.

## Verify

```bash
kubectl get agentcoresandbox coder -n agent-sandbox-system -o yaml
kubectl get agentruntime -n agent-sandbox-system
ID=$(kubectl get agentcoresandbox coder -n agent-sandbox-system -o jsonpath='{.status.runtimeID}')
aws bedrock-agentcore-control get-agent-runtime --region us-west-2 \
  --agent-runtime-id "$ID" --query '{status:status,platformVersion:platformVersion,agentRuntimeArn:agentRuntimeArn}'
```

Wait for `status.runtimeStatus=READY` and a non-empty `runtimeARN` before
invoking. `AgentCoreSandbox.status` is an ACK projection; the AWS API is the
source of truth for current runtime state. Creation and V2 snapshot preparation
can take minutes.

On a PUBLIC ↔ VPC switch, `task agentcore` waits for the AWS runtime to report
`READY`, V2, the requested image digest, and the requested network configuration.
See [verified runs and timings](../docs/SUBSTRATES.md) for the measured scope;
the VPC issue was different from the PUBLIC issue, not a latency comparison.

Switching back to PUBLIC creates another version. Check AWS for PUBLIC/READY/V2
before removing the Terraform security group. An earlier VPC version can still
hold its AgentCore-managed ENIs; even after that unused version is removed,
AWS says the ENIs may remain for **up to eight hours**. Do not manually detach
service-managed ENIs. Once they disappear, run the targeted Terraform apply to
remove the security group, then check the full plan.

## Session lifecycle and operational notes

`host.js` answers the first `GET /ping` with `Healthy` immediately, before
holding any session state. V2 snapshots that idle container on the first
healthy ping (required within 120 seconds) and restores it for each new
session. During a coder run `/ping` answers `HealthyBusy`, which keeps that
session out of its idle timeout. The default idle timeout is 900 seconds and
the maximum lifetime is 28800 seconds. V2 container environment variables
have a 2.5 KB limit; issue context and the GitHub token travel in the invoke
payload instead. Only `/tmp` is writable; the token is stored at
`/tmp/secrets/gh-token` (0600) and the coder workspace is `/tmp/workspace`.

Each round gets a new Argo workflow UID as its session ID. On a fix round the
coder clones the existing `df/issue-N` branch from GitHub; no session storage
or persistent local filesystem is used. The workflow calls
`StopRuntimeSession` after the PR appears, in parallel with review gates, and
again at exit as a safeguard.
The in-process `409` guard prevents concurrent launches in one live container,
but it does **not** ensure exactly-once execution after runtime loss. If an
invoke result is ambiguous, stop the prior session before retrying.

ACK 1.15.1 does not expose `AgentRuntime.spec.platformVersion` or
`capacityProviderConfiguration`, and it has no `CapacityProvider` CRD. The
Taskfile defaults `AGENTCORE_PLATFORM_VERSION` to `V2`, calls the AWS
`update-agent-runtime` API after the runtime reports READY with the requested
network configuration, and waits for READY again;
do not add that field to this RGD. AgentCore Runtime Instances (ACRI) remain
blocked on an ACK SDK-model update. This chart declares ordinary AgentCore
Runtime only.
