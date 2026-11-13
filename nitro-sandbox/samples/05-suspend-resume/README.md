# Suspend and resume a sandbox

One agent-sandbox `Sandbox` object gives you a pod in its own microVM, a volume, and a
stable DNS name. Suspending it deletes the pod and frees the VM; the volume and the name
stay. Resuming boots a new microVM on the same volume. This is how an agent's workspace
outlives the VM it ran in.

Kata's `Suspended` works the same way. Neither one hibernates the VM: memory is lost,
files on the volume are not.

## Run it

Once per cluster, the StorageClass. Auto Mode has its own EBS driver and creates no
class, and the cluster's default `ebs-gp3` cannot attach to Auto Mode nodes:

```bash
kubectl apply -f storageclass.yaml
```

Then the sandbox. Run the dry run first: the `Sandbox` CRD keeps unknown fields under
`podTemplate`, so a misplaced field only shows up against the live API.

```bash
kubectl apply --dry-run=server -f sandbox.yaml
kubectl apply -f sandbox.yaml
kubectl wait -n nitro-demo --for=condition=Ready sandbox/agent-alice --timeout=420s
```

That took 18 seconds from a cold apply, including creating and attaching the EBS
volume. One object produced three:

```bash
kubectl get pod,pvc,svc -n nitro-demo -o json | jq -r \
  '.items[] | select(.metadata.ownerReferences[]?.kind=="Sandbox") | "\(.kind)/\(.metadata.name)"'
```

```
Pod/agent-alice
PersistentVolumeClaim/state-agent-alice
Service/agent-alice
```

Note the volume and the DNS name before you suspend:

```bash
kubectl get -n nitro-demo pvc/state-agent-alice -o jsonpath='{.spec.volumeName}{"\n"}'
kubectl get -n nitro-demo sandbox/agent-alice -o jsonpath='{.status.serviceFQDN}{"\n"}'
```

## Suspend, then resume

```bash
kubectl patch -n nitro-demo sandbox/agent-alice --type=merge -p '{"spec":{"operatingMode":"Suspended"}}'
kubectl get -n nitro-demo sandbox/agent-alice
```

```
NAME          READY   REASON             AGE
agent-alice   False   SandboxSuspended   35s
```

The pod was gone 2.3 seconds after the patch, and with it the microVM and its slot on
the node. The PVC stays `Bound` and the Service stays. Bring it back:

```bash
kubectl patch -n nitro-demo sandbox/agent-alice --type=merge -p '{"spec":{"operatingMode":"Running"}}'
kubectl wait -n nitro-demo --for=condition=Ready sandbox/agent-alice --timeout=420s
kubectl logs -n nitro-demo agent-alice | head -3
```

```
=== total starts: 2 ===
start at 2026-10-05T15:59:56Z on i-0abc1234567890def
start at 2026-10-05T16:00:26Z on i-0abc1234567890def
```

Resume to `Ready` took 10.3 seconds. Run the two commands from before again: the PV name
and `agent-alice.nitro-demo.svc.cluster.local` should both be unchanged. A different PV
name would mean a new volume, and then the log would tell you nothing about durability.

## Why the manifest looks the way it does

- **`sync` after the write.** An earlier preview build silently lost writes that an
  init container made to a volume without a `sync`. That no longer reproduced on
  2026-10-05, but flushing before you report success costs nothing.
- **`readinessProbe` every 2 seconds.** The probe interval is part of resume latency; a
  10-second period can add 10 seconds to every resume.
- **`ReadWriteOncePod`.** A sandbox is one pod, and so is its volume.

## Clean up

```bash
kubectl delete -f sandbox.yaml
```

Deleting the `Sandbox` removes the pod, Service and PVC through owner references, and the
`Delete` reclaim policy removes the EBS volume within a minute. Keep `nitro-ebs` if you
plan to run this again.
