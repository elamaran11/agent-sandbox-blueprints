# Kata micro-VM substrate

Runs each agent sandbox as a **pod with its own kernel** on nested-virtualization
EKS nodes. This is the production-ready substrate: standard `kubectl` access,
in-cluster networking, and persistent workspaces.

```bash
task kata      # installs everything in this folder
```

## What gets installed

| Chart | What it does |
|---|---|
| `runtimeclasses/` | The three `RuntimeClass` objects workloads select, plus the **devmapper** `StorageClass` Firecracker requires |
| `kata-deploy/` | Upstream [kata-deploy](https://github.com/kata-containers/kata-containers) (OCI chart, pinned `3.32.0`) — installs the Kata runtime + containerd handlers for **QEMU and Cloud Hypervisor** |
| `kata-deploy-fc/` | The separate **Firecracker** install (different snapshotter, so it is its own release) |
| `nodepools/` | Karpenter `EC2NodeClass` + `NodePool` objects that provision nested-virt nodes on demand |

## Choose a hypervisor (VMM)

All three are installed. A workload picks one with `runtimeClassName`.

| | `kata-clh` (default) | `kata-qemu` | `kata-fc` |
|---|---|---|---|
| Hypervisor | Cloud Hypervisor | QEMU | Firecracker |
| Boot time | Fast | Slowest | Fastest |
| Memory overhead | Low | Highest | Lowest |
| **Volume sharing** (`virtio-fs`) | ✅ | ✅ | ❌ **not supported** |
| **GPU passthrough** (VFIO) | ❌ | ✅ **only option** | ❌ |
| Storage | overlayfs | overlayfs | **devmapper** (hence the StorageClass) |
| Use it for | Default choice for agent sandboxes | GPU workloads | Highest-density, no-volume workloads |

**Practical guidance**

- **Start with `kata-clh`.** It is the default because it balances boot speed against
  full feature support, and the agent needs a mounted workspace.
- **Use `kata-qemu` if you need a GPU.** It is the only VMM here that does VFIO PCIe
  passthrough. You will also need a GPU instance family that exposes nested
  virtualization, plus the NVIDIA device plugin.
- **`kata-fc` cannot mount volumes.** Firecracker has no `virtio-fs`, so anything that
  needs a shared workspace volume will not run under it. It is included because it is
  the leanest VMM and useful for stateless, high-density sandboxes — but the Dark
  Factory agent, which mounts a workspace, should use `clh` or `qemu`.

## How nodes get nested virtualization

Kata needs hardware virtualization *inside* an EC2 instance. Two consequences:

1. **Karpenter provisions the nodes**, using
   `EC2NodeClass.spec.cpuOptions.nestedVirtualization: enabled`. This needs
   **Karpenter ≥ 1.13** and **Kubernetes ≥ 1.36** — which is why
   `infrastructure/terraform` pins `cluster_version = "1.36"`.
2. **Stock AL2023 AMI, no custom image.** `kata-deploy` installs the runtime at
   node startup, so there is no Packer step. Bottlerocket and EKS Auto Mode cannot
   host Kata, because Kata needs control of containerd.

Pools are provided for nested-virt and, as a fallback, bare-metal (some regions run
short of nested-virt capacity), for both the qemu/clh and fc families.

## The startup-taint dance (why there are readiness DaemonSets)

A node is not ready for Kata pods the moment it joins — the runtime still has to
install. So each node is born with a `katacontainers.io/runtime-not-ready` startup
taint, and a small readiness DaemonSet removes it once install completes.

Two traps this design avoids, both learned the hard way:

- **The `kata-enabled` label must exist at node birth.** The RuntimeClasses carry
  `scheduling.nodeSelector`, and the RuntimeClass admission controller force-merges it
  into every Kata pod. If the label only appeared *after* install, Karpenter could never
  schedule the first pod — a cold-start deadlock.
- **Readiness must come from `kata-deploy`'s `/readyz`, not from the
  `katacontainers.io/kata-runtime` label.** That label is now set at birth by the
  NodePool (see above), so it says nothing about whether install finished. The
  DaemonSet watches the kata-deploy pod's readiness probe instead, which returns 503
  during install and 200 only when it is genuinely done.

## Verify

```bash
kubectl get runtimeclass | grep kata            # kata-clh, kata-qemu, kata-fc
kubectl get nodepool,ec2nodeclass              # Karpenter pools
kubectl get ds -n kube-system | grep kata      # kata-deploy + readiness

# Smoke test — should reach Running on a Karpenter-provisioned nested-virt node
kubectl run kata-smoke --rm -it --restart=Never \
  --image=public.ecr.aws/docker/library/busybox:latest \
  --overrides='{"spec":{"runtimeClassName":"kata-clh","tolerations":[{"key":"kata","operator":"Equal","value":"true","effect":"NoSchedule"}]}}' \
  -- uname -a
```

That last command is the real test: the kernel version it prints is the **guest**
kernel, not the host's — proof the pod is in its own VM.

> Local `helm template` of `kata-deploy/` fails until you run `helm dependency build`
> (it pulls an OCI chart). ArgoCD resolves chart dependencies itself, so this only
> affects local rendering.

## Next

Run the agent on this substrate: [`examples/dark-factory-kata`](../examples/dark-factory-kata/README.md)
