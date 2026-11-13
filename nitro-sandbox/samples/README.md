# Nitro Sandbox samples

Six short walkthroughs of how a sandbox behaves on EKS Pod Isolation. Each is a manifest
or two plus a README with the commands and the output they printed. Every result was
measured on 2026-10-05 on EKS 1.36 Auto Mode (`m7i.xlarge`, Bottlerocket 2026.9.30,
agent-sandbox v0.5.4). The feature is a private preview, so re-run a sample before you
build on its numbers.

**Prerequisites:** `task nitro` is done (see [`../README.md`](../README.md)), and the
samples namespace exists:

```bash
kubectl create ns nitro-demo
```

The RuntimeClasses carry the toleration for the sandbox NodePool's taint, so the
manifests only set `runtimeClassName`. The first sandbox pod waits about 45 seconds
while Auto Mode launches a node; after that, pods start in seconds.

| Sample | What it shows | Needs |
|---|---|---|
| [`01-hello-sandbox`](01-hello-sandbox/README.md) | The smallest pod in its own microVM, and how to check that it is one | Nothing else |
| [`02-sizing`](02-sizing/README.md) | Requests size the VM, limits do not, and the overlay comes from an ephemeral-storage limit | Nothing else |
| [`03-network-isolation`](03-network-isolation/README.md) | One annotation removes the guest's network, and the old key that silently does nothing | Nothing else |
| [`04-network-policy`](04-network-policy/README.md) | Keeping an agent on the internet and off the cluster with a NetworkPolicy | NetworkPolicy enforcement |
| [`05-suspend-resume`](05-suspend-resume/README.md) | An agent-sandbox `Sandbox` with a volume: suspend, resume, same state, same DNS name | The `nitro-ebs` StorageClass in that folder |
| [`06-warm-pool`](06-warm-pool/README.md) | Pre-booted spares, a warm claim against a cold one, and why claims that inject env skip the pool | Nothing else |

Run 01 first. It is the quickest way to know whether the cluster can boot a sandbox at
all, and everything after it assumes one can.

02 and 03 each start three pods. Run the samples one at a time and clean up in
between; anything that does not fit on the current node makes Auto Mode add one.

## Clean up

```bash
kubectl delete ns nitro-demo
kubectl delete storageclass nitro-ebs --ignore-not-found   # if you ran 05
```

Empty sandbox nodes are removed 10 minutes later.
