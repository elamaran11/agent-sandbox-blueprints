# Internet yes, cluster no

An agent usually needs the internet (GitHub, package registries, a model API) and has
no business talking to anything else in your cluster. A sandbox pod is an ordinary CNI
endpoint, so a standard NetworkPolicy does exactly that. This sample puts one on an
`agent` sandbox and checks what it can still reach.

**Prerequisite:** the cluster must enforce NetworkPolicy, or every policy here is
accepted and does nothing. On Auto Mode that is the `amazon-vpc-cni` ConfigMap (see
[Use network policies with EKS Auto Mode](https://docs.aws.amazon.com/eks/latest/userguide/auto-net-pol.html)).
Check before you trust a result:

```bash
kubectl get configmap amazon-vpc-cni -n kube-system -o jsonpath='{.data.enable-network-policy-controller}{"\n"}'   # true
```

> Turning enforcement on also enforces the NetworkPolicy agent-sandbox puts on every
> SandboxTemplate. A template without its own `networkPolicy` then reaches only the
> public internet, which cuts it off from in-cluster services such as Bifrost. The
> Nitro coder template sets its own list; check any other template you run.

## Run it

```bash
kubectl apply -f pods.yaml
kubectl wait -n nitro-demo --for=condition=Ready pod/server pod/agent --timeout=300s
```

A probe to reuse, from the agent to the server's Service, to the server's pod IP, and
to the internet:

```bash
probe() {
  SERVER_IP=$(kubectl get pod -n nitro-demo server -o jsonpath='{.status.podIP}')
  for t in server.nitro-demo.svc.cluster.local:8080 "$SERVER_IP:8080" 1.1.1.1:443; do
    r=$(kubectl exec -n nitro-demo agent -- bash -c "timeout 5 bash -c 'exec 3<>/dev/tcp/${t%:*}/${t##*:}' 2>/dev/null && echo open || echo blocked")
    printf '%-42s %s\n' "$t" "$r"
  done
}
probe
```

```
server.nitro-demo.svc.cluster.local:8080   open
10.0.135.130:8080                          open
1.1.1.1:443                                open
```

Now apply the policy, give it a few seconds, and probe again:

```bash
kubectl apply -f internet-only.yaml
sleep 5 && probe
```

```
server.nitro-demo.svc.cluster.local:8080   blocked
10.0.135.130:8080                          blocked
1.1.1.1:443                                open
```

Delete it and the agent reaches the server again:

```bash
kubectl delete -f internet-only.yaml
sleep 5 && probe
```

## What you should see

| | No policy | `internet-only.yaml` |
|---|---|---|
| Server by Service name | open | blocked |
| Server by pod IP | open | blocked |
| Public internet | open | open |
| Cluster DNS | resolves | resolves (the policy allows kube-dns) |

A direct lookup, since the probe above only exercises TCP connects to known addresses:

```bash
kubectl exec -n nitro-demo agent -- getent ahosts github.com | head -1
kubectl exec -n nitro-demo agent -- getent ahosts server.nitro-demo.svc.cluster.local | head -1
```

Both return an address: cluster lookups go to CoreDNS through the policy's kube-dns
allow rule, and the recursive answer rides back on the public-internet rule. If this
hangs or returns nothing, check that your CoreDNS pods carry `k8s-app: kube-dns` (the
label the policy selects).

The policy took effect about 3 seconds after `kubectl apply`. It allows egress to
cluster DNS and to every public address, and drops the private ranges, which covers
other pods, Services, the API server and the rest of the VPC in one rule.

The microVM boundary and the policy protect different things. The VM keeps a
compromised agent off the node's kernel; the policy keeps it off your network. A sandbox
needs both.

## Clean up

```bash
kubectl delete -f internet-only.yaml --ignore-not-found
kubectl delete -f pods.yaml
```
