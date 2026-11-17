# Sizing a sandbox

A sandbox's microVM is built from the pod's **requests**. Limits do not size it, with
one exception that runs the other way. Getting this wrong costs nothing visible: the pod
runs, the status is green, and the VM is smaller than you think.

## Run it

```bash
kubectl apply -f pods.yaml
kubectl wait -n nitro-demo --for=condition=Ready pod/size-requests pod/size-limits-only pod/size-small --timeout=300s
for p in size-requests size-limits-only size-small; do echo "--- $p"; kubectl logs -n nitro-demo $p; done
```

```
--- size-requests
vCPUs:   1
memory:  2138 MiB
overlay: 3.9G
--- size-limits-only
vCPUs:   2
memory:  1134 MiB
--- size-small
vCPUs:   1
memory:  884 MiB
```

## What you should see

| Pod | Asks for | Gets |
|---|---|---|
| `size-requests` | `requests: cpu: "1", memory: 2Gi` and `limits: ephemeral-storage: 4Gi` | 1 vCPU, 2138 MiB, a 3.9G writable overlay |
| `size-limits-only` | `limits: cpu: "2", memory: 1Gi`, no requests | 2 vCPUs, 1134 MiB |
| `size-small` | `requests: cpu: 250m, memory: 768Mi` | 1 vCPU, 884 MiB |

Read them in this order:

- **Memory is the request plus 256Mi.** The RuntimeClass adds the 256Mi as pod overhead
  and the VM gets it. The guest kernel keeps some of it, so `MemTotal` reads 140 to 170
  MiB below the VM's size: 884 MiB for 768Mi, 1134 MiB for 1Gi, 2138 MiB for 2Gi.
- **A limit above the request is unreachable.** The VM only has what the request bought.
  Set memory limits equal to requests.
- **Limits alone still work, by accident.** `size-limits-only` has no requests, so the
  API server copies its limits into them, and the VM is sized from those:

  ```bash
  kubectl get pod -n nitro-demo size-limits-only -o jsonpath='{.spec.containers[0].resources.requests}{"\n"}'
  ```

  ```
  {"cpu":"2","memory":"1Gi"}
  ```

- **There are no fractional vCPUs.** 250m boots a whole vCPU, and so does 1000m. One
  millicore more doubles it: a `cpu: 1001m` request boots 2 vCPUs. The scheduler still
  books only what you asked for, so twenty 100m sandboxes fit on a 4-vCPU node and share
  its four cores. See the capacity section in [`../../README.md`](../../README.md).
- **The overlay comes from the ephemeral-storage *limit*,** backwards from cpu and
  memory. Every `emptyDir` in the pod lives inside it, not on the node's disk:

  ```bash
  kubectl exec -n nitro-demo size-requests -- df -h /
  ```

  ```
  Filesystem      Size  Used Avail Use% Mounted on
  overlay         3.9G   95M  3.8G   3% /
  ```

You cannot resize a running sandbox in place. Change the requests and recreate the pod.

## Clean up

```bash
kubectl delete -f pods.yaml
```
