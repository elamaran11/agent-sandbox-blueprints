# Hello, sandbox

The smallest pod that runs in its own microVM, and how to check that it really is one.

## Run it

```bash
kubectl apply -f pod.yaml
kubectl wait -n nitro-demo --for=condition=Ready pod/hello-sandbox --timeout=300s
kubectl logs -n nitro-demo hello-sandbox
```

If no sandbox node is up yet, Auto Mode launches one first: about 45 seconds from apply
to `Running`. On a node that already had the image it took 6 seconds.

```
machine: m7i.enclave
vCPUs:   1
memory:  884 MiB
kernel:  6.18.48
uptime:  2.60s
```

## Prove it is a VM

Put that next to the node the pod landed on:

```bash
NODE=$(kubectl get -n nitro-demo pod/hello-sandbox -o jsonpath='{.spec.nodeName}')
kubectl get node "$NODE" -o custom-columns='TYPE:.metadata.labels.node\.kubernetes\.io/instance-type,CPU:.status.capacity.cpu,MEMORY:.status.capacity.memory,KERNEL:.status.nodeInfo.kernelVersion'
```

```
TYPE         CPU   MEMORY       KERNEL
m7i.xlarge   4     16101344Ki   6.18.48
```

| | Inside the pod | The node |
|---|---|---|
| Machine | `m7i.enclave` | `m7i.xlarge` |
| vCPUs | 1 | 4 |
| Memory | 884 MiB | about 15.4 GiB |
| Uptime | a few seconds | since the node booted |

A container on this node would see 4 CPUs and the node's memory, because it shares the
node's kernel. The sandbox sees only the VM its requests bought: one vCPU, and 768Mi plus
the RuntimeClass's 256Mi overhead, of which the guest kernel reports 884 MiB.
[`02-sizing`](../02-sizing/README.md) covers how that works.

Do not use the kernel version as the proof. On today's Auto Mode AMI the guest and the
node both run 6.18.48, so matching versions say nothing about isolation. If the machine
name is the node's instance type and `nproc` matches the node, the pod did not get a VM:
check that `runtimeClassName` was accepted.

```bash
kubectl get -n nitro-demo pod/hello-sandbox -o jsonpath='{.spec.runtimeClassName}{"\n"}'
```

## If it does not start

| Symptom | Cause | Fix |
|---|---|---|
| `Pending`, no node appears | No sandbox-capable node and the NodePool cannot launch one | `kubectl get nodepool nitro-sandbox` should be Ready; check the NodeClass is Ready and that the instance types are in your account's quota |
| Rejected at create with `RuntimeClass ... not found` | The RuntimeClass is missing or misspelled | `kubectl get runtimeclass`; the names use hyphens |
| `Pending` with `Insufficient eks.amazonaws.com/nitro-sandbox` | Every sandbox slot on the node is in use (20 on an `m7i.xlarge`) | Auto Mode adds a node for it; to free slots, delete idle sandboxes |
| `ContainerCreating` for minutes, events repeat `FailedCreatePodSandBox` with `No space left on device` | An older node image that boots fewer microVMs than it advertises | Delete idle sandboxes, or replace the node so it comes up on a current image |

## Clean up

```bash
kubectl delete -f pod.yaml
```
