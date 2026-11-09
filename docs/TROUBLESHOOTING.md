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

## Nitro Sandbox

| Symptom | Cause | Fix |
|---|---|---|
| `task nitro` stops: no EKS Auto Mode node role | Terraform ran without Auto Mode | `enable_auto_mode = true` in `terraform.tfvars`, then `task tf:apply` |
| Sandbox pod `Pending`, Auto Mode launches nothing | The `nitro-sandbox` NodeClass is not Ready, or the account is not enabled for the preview | `kubectl get nodeclass,nodepool nitro-sandbox`; a capable node carries `eks.amazonaws.com/nitro-sandbox=true` and a non-zero `eks.amazonaws.com/nitro-sandbox` allocatable |
| Pod rejected: `RuntimeClass "isolated_sandbox" not found` | The preview guide spells the names with underscores | Use hyphens: `isolated-sandbox`, `confidential-sandbox` |
| Pod `Pending` with `Insufficient eks.amazonaws.com/nitro-sandbox` | All 20 sandbox slots on the node are in use | Auto Mode adds a node unless the pod is pinned to one; delete idle sandboxes |
| Pod in `ContainerCreating` for minutes, events repeat `FailedCreatePodSandBox` with `No space left on device` | An older preview node image that booted fewer microVMs than it advertised | Replace the node so it comes up on a current image; until then delete idle sandboxes |
| `confidential-sandbox` pod never starts: `a policy is required in confidential mode` | That RuntimeClass is default-deny without a Cedar policy envelope | Use `isolated-sandbox`, or attach a `sandbox.amazonaws.com/policy` envelope |
| Coder cannot reach Bifrost; cluster names do not resolve | agent-sandbox's default template NetworkPolicy allows public internet only and swaps DNS to `8.8.8.8` | Set `networkPolicy` on the SandboxTemplate; the Nitro coder template lists cluster DNS, Bifrost and the internet |
| PVC on a sandbox node never attaches | `ebs-gp3` uses the EBS CSI add-on, whose node plugin skips Auto Mode nodes | Use a class on `ebs.csi.eks.amazonaws.com` (`nitro-sandbox/samples/05-suspend-resume/storageclass.yaml`) |
| `deny-all-egress` annotation does nothing | The annotation was renamed and the old key is ignored | `sandbox.amazonaws.com/network-isolated: "true"` |
| DNS lookups time out under load | The guest is capped at 100 DNS packets per second | Fewer parallel lookups; the cap has no override |
| Guest and node report the same kernel | Today's Auto Mode AMI runs the same kernel in both | Check `/sys/class/dmi/id/product_name` (`m7i.enclave` or `m8i.enclave`) and `nproc` instead |

## Pipeline

| Symptom | Cause | Fix |
|---|---|---|
| `task demo-*` fails on `dark-factory-webhook` with `spec.loadBalancerClass ... may not change once set` | The Service was created before the AWS Load Balancer Controller was installed, so it has no class, and the class cannot be added in place | `kubectl delete svc dark-factory-webhook -n argo-events`, re-run `task demo-*`, then point the GitHub webhook at the new NLB address |
| Webhook arrives, no Workflow created | Sensor has stale JetStream consumers after an EventBus restart | Delete the stale consumers and restart the sensor |
| Your "fix findings" comment does nothing | The pipeline posts as the token owner and ignores its own voice | Comment from a **different** GitHub account |
| Merge refused despite green checks | Stale findings from an earlier commit being counted | Judge by commit statuses on the **current head**; inline comments carry forward |
| Agent re-ran but committed nothing | The review note never reached the sandbox | The note must ride in the sandbox's injected env / run payload |
| Reviews restart on every push | Each new commit re-triggers the external agents (8–15 min each) | Expected; batch fixes into one commit where you can |
| Runs pile up and stall | Concurrency is bounded by node capacity: coder claims inject env, so they skip the warm pool ([ROADMAP #9](ROADMAP.md#9-a-claim-that-injects-env-never-uses-the-warm-pool)) and wait for room on a node | Raise the NodePool `cpuLimit` (`kata/nodepools/values.yaml`, `nitro-sandbox/nodepools/values.yaml`), or accept the queue |

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
