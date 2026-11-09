# Warm pool

A `SandboxWarmPool` keeps spare sandboxes booted before anyone asks for one, so a claim
binds to a running microVM instead of waiting for a boot. This sample builds a pool of
two, claims one, and times a warm claim against a cold one.

## Run it

```bash
kubectl apply -f warmpool.yaml
kubectl get sandboxes -n nitro-demo -w     # Ctrl-C once both spares are READY True
```

The two spares were ready 11 seconds after the apply, on a node that already had the
image. Now claim one:

```bash
time (kubectl apply -f claim.yaml && \
  kubectl wait -n nitro-demo --for=condition=Ready sandboxclaim/user-alice --timeout=120s)
kubectl get sandboxclaim -n nitro-demo user-alice -o jsonpath='{.status.sandbox.name}{"\n"}'
```

The claim was `Ready` in 2 to 3 seconds (3.3 s and 2.4 s in two runs) and bound to one
of the two spares, which carries `agents.x-k8s.io/launch-type: warm`. The pool then
booted a replacement, so it is back to two idle spares.

## Warm against cold

Empty the pool and claim again:

```bash
kubectl patch sandboxwarmpool -n nitro-demo demo-pool --type=merge -p '{"spec":{"replicas":0}}'
kubectl get sandboxes -n nitro-demo -l agents.x-k8s.io/warm-pool-sandbox   # wait until none are left

time (kubectl apply -f - <<'EOF' && kubectl wait -n nitro-demo --for=condition=Ready sandboxclaim/user-bob --timeout=180s
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxClaim
metadata:
  name: user-bob
  namespace: nitro-demo
spec:
  warmPoolRef:
    name: demo-pool
EOF
)
```

| Claim | Ready after (two runs) | `launch-type` |
|---|---|---|
| `user-alice`, pool full | 3.3 s, 2.4 s | `warm` |
| `user-bob`, pool empty | 8.7 s, 8.5 s | `cold` |

Both ran on a node that already had the image. On a node without it, a cold claim also
pays the image pull and the first-boot conversion, and on a cluster with no sandbox node
up it waits for Auto Mode to launch one, about 45 seconds. That is where a pool earns
its keep.

## Claims that inject env skip the pool

A spare boots before any user exists, so it cannot carry per-claim env. agent-sandbox
handles a claim that injects env by booting a fresh sandbox and leaving the spares
alone. This template sets `envVarsInjectionPolicy: Disallowed`, so such a claim is
refused instead of silently going cold:

```bash
kubectl apply -f - <<'EOF'
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxClaim
metadata:
  name: user-carol
  namespace: nitro-demo
spec:
  warmPoolRef:
    name: demo-pool
  env:
    - { containerName: app, name: USER_TOKEN, value: "x" }
EOF
kubectl get sandboxclaim -n nitro-demo user-carol -o jsonpath='{.status.conditions[0].reason}: {.status.conditions[0].message}{"\n"}'
```

```
EnvVarsInjectionRejected: environment variable injection rejected: environment variable injection is not allowed by the template policy
```

The Dark Factory needs per-claim env (the issue number, the repo), so its template allows
injection and every claim is a cold start on a warm node. See
[`../../README.md`](../../README.md#the-coder-template).

## Sizing the pool

Every spare is a running microVM. It holds its CPU and memory requests and one of the
node's sandbox slots for as long as it waits. Size the pool from how often claims arrive,
not as high as the slot count suggests.

## Clean up

```bash
kubectl delete sandboxclaim -n nitro-demo user-alice user-bob user-carol --ignore-not-found
kubectl delete -f warmpool.yaml
```
