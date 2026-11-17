# Cutting a sandbox off the network

One annotation boots the guest with no network device at all. That is a stronger
guarantee than a firewall rule, because there is nothing left to misconfigure. The
sample also shows the old spelling of the annotation, which the runtime now ignores.

## Run it

```bash
kubectl apply -f pods.yaml
kubectl wait -n nitro-demo --for=condition=Ready pod/no-network pod/with-network pod/legacy-key --timeout=300s
for p in no-network with-network legacy-key; do echo "--- $p"; kubectl logs -n nitro-demo $p; done
```

```
--- no-network
interfaces:    dummy0 lo
default route: none
--- with-network
interfaces:    dummy0 eth0 lo
default route: yes
--- legacy-key
interfaces:    dummy0 eth0 lo
default route: yes
```

Then try to leave the guest, from all three:

```bash
for p in no-network with-network legacy-key; do
  printf '%-13s ' "$p"
  kubectl exec -n nitro-demo $p -- bash -c 'timeout 8 bash -c "exec 3<>/dev/tcp/1.1.1.1/443" 2>/dev/null && echo "1.1.1.1:443 reachable" || echo "1.1.1.1:443 unreachable"'
done
```

```
no-network    1.1.1.1:443 unreachable
with-network  1.1.1.1:443 reachable
legacy-key    1.1.1.1:443 reachable
```

## What you should see

| Pod | Annotation | Interfaces | Egress |
|---|---|---|---|
| `no-network` | `sandbox.amazonaws.com/network-isolated: "true"` | `dummy0`, `lo` | None. DNS fails too |
| `with-network` | none | `dummy0`, `eth0`, `lo` | Normal |
| `legacy-key` | `sandbox.amazonaws.com/deny-all-egress: "true"` | `dummy0`, `eth0`, `lo` | **Normal** |

`with-network` is the control. If it cannot reach the internet either, your cluster has
no egress and the `no-network` result proves nothing.

`legacy-key` is the trap. `deny-all-egress` was the annotation's earlier name, and the
runtime silently ignores it now: no warning, no event, and the pod is fully connected
while its manifest says the opposite. If you have manifests or admission policies that
check for `deny-all-egress`, they are checking for nothing.

`kubectl logs` and `kubectl exec` still work on `no-network`, because they reach the
guest over vsock rather than its network. You just ran `exec` against it.

## What it does not do

It is all or nothing. There is no allow-list, so an agent that needs GitHub or a model
endpoint cannot use it. For "the internet but not the cluster", use a NetworkPolicy:
[`04-network-policy`](../04-network-policy/README.md).

## Clean up

```bash
kubectl delete -f pods.yaml
```
