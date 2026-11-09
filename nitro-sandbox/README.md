# Nitro Sandbox substrate

Runs each agent sandbox as a **pod inside its own microVM**, carved out of the node by
Nitro Enclaves. This is EKS Pod Isolation, and workloads opt in with one field:
`runtimeClassName: isolated-sandbox`. You get standard `kubectl`
access and in-cluster networking like Kata, without nested virtualization or a
runtime to install on the node.

> **Private preview.** EKS Pod Isolation is not generally available. Your account must
> be enabled for the preview, and RuntimeClass names, annotation keys and the numbers
> on this page can change before launch. Everything here was measured on 2026-10-05
> on EKS 1.36 Auto Mode (Bottlerocket 2026.9.30) with agent-sandbox v0.5.4.

```bash
task nitro     # installs everything in this folder
```

## Before you start

Pod isolation runs on **EKS Auto Mode** nodes, and the blueprint cluster has Auto Mode
off by default. Turn it on in `infrastructure/terraform/terraform.tfvars`:

```hcl
enable_auto_mode = true
```

On a cluster you already run, `task tf:plan` first: `module.eks.aws_eks_cluster.this[0]`
must show as updated in place, never replaced. Then `task tf:apply`. This enables Auto
Mode compute, block storage and load balancing
(EKS turns the three on together) next to the system node group and the Kata Karpenter
pools. No built-in node pools are enabled, so nothing moves onto Auto Mode unless it asks
for a sandbox. It also creates the Auto Mode node role and its access entry. `task nitro`
refuses to run until that role exists.

## What gets installed

| Chart | What it does |
|---|---|
| `nodepools/` | An Auto Mode `NodeClass` (private subnets, the cluster's node security group) and a `NodePool` limited to the instance types that support pod isolation, tainted `nitro-sandbox` |
| `runtimeclasses/` | The two RuntimeClasses, `isolated-sandbox` and `confidential-sandbox`, with the per-pod overhead and a toleration for that taint |
| `sandbox-templates/` | The coder `SandboxTemplate` + `SandboxWarmPool` that [`examples/dark-factory-nitro`](../examples/dark-factory-nitro/README.md) claims from |

There is nothing to install on the node. On a cluster enabled for the preview, Auto
Mode gives every supported instance type the sandbox runtime and labels the node
`eks.amazonaws.com/nitro-sandbox=true`. The pool starts at zero nodes: the first
pending sandbox pod makes Auto Mode launch one, about 45 seconds from apply to a
running pod.

## Choose a RuntimeClass

| | `isolated-sandbox` | `confidential-sandbox` |
|---|---|---|
| Boundary | Own microVM: own kernel, vCPUs and memory | Same |
| Writable overlay | Plain | Encrypted (LUKS, per the preview's earlier testing) |
| Without a policy envelope | Runs | **Refuses to start** |
| Use it for | Agent sandboxes, including the Dark Factory coder | Workloads with a Cedar policy from the preview's `genpolicy` tool |

**Start with `isolated-sandbox`.** `confidential-sandbox` is default-deny: a pod
without a `sandbox.amazonaws.com/policy` annotation sits in `ContainerCreating` while
its events repeat `a policy is required in confidential mode (default-deny is
enforced)`. Generating that policy needs a preview-only tool, and the policy pins the
pod's spec and name, which a controller-named warm spare cannot match.

Spell the names with hyphens. The preview guide writes `isolated_sandbox`, and a pod
that uses the underscore is rejected at create with `RuntimeClass "isolated_sandbox" not
found`.

## How a microVM is sized

The VM is built from the pod's **requests**, not its limits. Measured on `m7i.xlarge`:

| Pod asks for | Guest gets |
|---|---|
| `requests: cpu: "1", memory: 2Gi` | 1 vCPU, 2138 MiB |
| `requests: cpu: 250m, memory: 768Mi` | 1 vCPU, 884 MiB (no fractional vCPUs) |
| `requests: cpu: 1001m` | 2 vCPUs |
| `limits: cpu: "2", memory: 1Gi` and no requests | 2 vCPUs, 1134 MiB (requests default from limits) |
| `limits: ephemeral-storage: 4Gi` | a 3.9G writable overlay |

So set requests to what the workload needs and memory limits equal to them. A limit
above the request cannot be reached, because the VM only has what the request bought.
`ephemeral-storage` is the odd one out: its **limit** sizes the guest's writable
overlay, and every `emptyDir` lives inside that overlay rather than on the node's disk.
The RuntimeClass adds `256Mi` of memory and one `eks.amazonaws.com/nitro-sandbox` to
every pod's scheduling footprint. [`samples/02-sizing`](samples/02-sizing/README.md)
shows all of this.

## How many sandboxes fit on a node

An `m7i.xlarge` or `m8i.xlarge` advertises 20 `eks.amazonaws.com/nitro-sandbox` slots, and
on today's AMI the slots are real: twenty sandboxes at `cpu: 100m` ran at once on one
`m7i.xlarge`, and the 21st stayed `Pending` with `Insufficient
eks.amazonaws.com/nitro-sandbox`. So the scheduler's normal accounting is the limit:
CPU and memory requests (plus the 256Mi overhead) and those 20 slots, whichever runs out
first. When a node is full, Auto Mode adds another.

With `cpu: "1"` requests CPU runs out first, at three per node (3770m allocatable), and
that is what the coder template requests. Sub-core sandboxes fit more densely, but each
guest still gets a whole vCPU, so twenty of them on a 4-vCPU node share four cores.

Earlier preview builds booted far fewer microVMs than the slots they advertised (one or
four per node) and left the rest in `ContainerCreating` with `No space left on device` in
the events. If you see that, the node is probably on an older image.

## Networking

A sandbox pod is an ordinary CNI endpoint. It gets a VPC IP, `kubectl logs` and `exec`
work, and NetworkPolicy applies to it when the cluster enforces policy. Three things to
know:

- **`sandbox.amazonaws.com/network-isolated: "true"`** boots the guest with no network
  device at all. The older key, `sandbox.amazonaws.com/deny-all-egress`, is silently
  ignored and leaves the pod fully connected. See
  [`samples/03-network-isolation`](samples/03-network-isolation/README.md).
- **DNS is rate limited** per guest. Of 200 lookups fired at once, about 95 timed out,
  every time we ran it; 20 in a row all answered. The preview documents the limit as 100
  DNS packets per second, and each lookup sends two (A and AAAA). There is no annotation
  to raise it.
- **agent-sandbox adds its own NetworkPolicy** to every `SandboxTemplate`. Unless the
  template sets `networkPolicy`, that policy allows the public internet only and
  rewrites the pod's DNS to `8.8.8.8` and `1.1.1.1`. On a cluster that enforces
  NetworkPolicy this cuts a template's pods off from every Service, including an
  in-cluster LLM gateway. The coder template sets an explicit list instead: cluster
  DNS, Bifrost and the public internet. See [`sandbox-templates/values.yaml`](sandbox-templates/values.yaml).

## The coder template

`sandbox-templates/` keeps the Kata coder's contract (container `coder`, env injected by
a `SandboxClaim`, the GitHub token at `/etc/secrets/gh-token`) and changes what the
microVM needs:

| Setting | Value | Why |
|---|---|---|
| `runtimeClassName` | `isolated-sandbox` | The isolation boundary |
| requests | `cpu: "1"`, `memory: 4Gi`, `ephemeral-storage: 10Gi` | Sizes the VM; 4Gi is what the Kata coder can burst to |
| limits | `memory: 4Gi`, `ephemeral-storage: 10Gi` | Memory equal to the request; the storage limit sizes the overlay holding `/workspace` and `/tmp` |
| `networkPolicy` | DNS, Bifrost, public internet | Replaces agent-sandbox's internet-only default |
| `terminationGracePeriodSeconds` | `5` | A terminating sandbox keeps its slot and resources until it is gone |

The Kata hardening carries over unchanged and works in the guest: non-root uid 1000,
`readOnlyRootFilesystem`, all capabilities dropped, no service account token, and the
`0400` secret is readable by the coder through `fsGroup`.

The warm pool does less than its name suggests. Every Dark Factory claim injects env,
and a claim that injects env never adopts the idle spare: agent-sandbox boots a fresh
sandbox from the template (`agents.x-k8s.io/launch-type: cold`). The spare's job is to
keep a sandbox node up with the coder image already pulled and converted. On such a node
the claimed coder's container starts about 4 seconds after scheduling. On a node without
the image the first coder took 27 seconds, most of it pulling the 1 GB image and
converting it on first boot. With no sandbox node up at all, Auto Mode launches one
first; that took about 45 seconds from apply to a running pod with a small image.

## Verify

```bash
kubectl get runtimeclass isolated-sandbox confidential-sandbox
kubectl get nodepool nitro-sandbox && kubectl get nodeclass nitro-sandbox
kubectl get sandboxwarmpool -n agent-sandbox-system coder-warmpool-nitro

# Nodes that can run sandboxes, and the slots they advertise
kubectl get nodes -l eks.amazonaws.com/nitro-sandbox=true \
  -o custom-columns='NODE:.metadata.name,TYPE:.metadata.labels.node\.kubernetes\.io/instance-type,SLOTS:.status.allocatable.eks\.amazonaws\.com/nitro-sandbox'
```

Then run [`samples/01-hello-sandbox`](samples/01-hello-sandbox/README.md). It is the
real test: the pod reports a machine called `m7i.enclave` (`m8i.enclave` on an m8i
node) with one vCPU, on a node that has four.

> Comparing `uname -r` inside the pod with the node's kernel no longer proves anything
> on Auto Mode: the guest and the node both run 6.18.48 on today's AMI. Use the
> machine name, vCPU count and memory instead.

## Samples

Six short, validated walkthroughs live in [`samples/`](samples/README.md): proving the
VM boundary, sizing, cutting the network, NetworkPolicy, a suspendable Sandbox with a
persistent volume, and a warm pool.

## Next

Run the agent on this substrate: [`examples/dark-factory-nitro`](../examples/dark-factory-nitro/README.md)
