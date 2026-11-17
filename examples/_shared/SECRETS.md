# Secrets

**Nothing here ever goes in git or in a values file** — manifests reference only a
Secret's *name*.

You need the same GitHub token in **three** places. Three components read it, in
different namespaces, under different key names. Creating only some of them is the most
common way to get stuck:

| Secret | Namespace | Keys | Read by |
|---|---|---|---|
| `dark-factory-github` | `argo` | `token` | The workflow steps: status comments, gates, merge |
| `dark-factory-github` | `argo-events` | `token`, `webhook-secret` | The EventSource: verifies the webhook HMAC, registers the webhook |
| `dark-factory-github` | `agent-sandbox-system` | `gh-token` | The coder inside the sandbox: clones, pushes, opens the PR |

Two details that fail unhelpfully if missed:

* The coder's key is **`gh-token`**, not `token`. The SandboxTemplate mounts the whole
  Secret at `/etc/secrets` and the agent reads `/etc/secrets/gh-token`.
* The coder's Secret is **not optional**. Until it exists, every warm-pool member sits
  in `ContainerCreating` indefinitely with
  `MountVolume.SetUp failed ... secret "dark-factory-github" not found`. The pod is
  scheduled and the Kata node is healthy, so this looks like a micro-VM problem when
  it is only a missing Secret. Create it **before** `task kata` or `task nitro`, or
  delete the stuck pods afterwards and the warm pool will recreate them.

## Option A — quickstart (`kubectl`)

Fine for a demo on a throwaway repo. The examples also render ExternalSecrets for these
same three Secrets (Option B). With this option, set `github.externalSecret.enabled: false`
under `dark-factory-shared:` in your `values.yaml` so the two do not fight over them.

```bash
GH_TOKEN="ghp_your_token_here"
# A random HMAC secret for the webhook; you will paste this into GitHub below.
WEBHOOK_SECRET="$(openssl rand -hex 20)"

for NS in argo argo-events agent-sandbox-system; do
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
done

# 1. For the EventSource (webhook verification + registration).
kubectl create secret generic dark-factory-github \
  --namespace argo-events \
  --from-literal=token="$GH_TOKEN" \
  --from-literal=webhook-secret="$WEBHOOK_SECRET"

# 2. For the coder in the sandbox — note the DIFFERENT key name.
kubectl create secret generic dark-factory-github \
  --namespace agent-sandbox-system \
  --from-literal=gh-token="$GH_TOKEN"

# 3. For the workflow steps, which run in the argo namespace.
kubectl create secret generic dark-factory-github \
  --namespace argo \
  --from-literal=token="$GH_TOKEN"

echo "Webhook secret (paste into GitHub): $WEBHOOK_SECRET"
```

### Token scope

Use a **fine-grained** personal access token limited to the single target repository:

| Permission | Level | Why |
|---|---|---|
| Contents | Read and write | Clone the repo, push the agent's branch |
| Pull requests | Read and write | Open the PR, comment status, merge on approval |
| Issues | Read and write | Read the issue spec, apply labels |
| Commit statuses | Read and write | Publish each gate's verdict on the commit |

**Do not** grant org-wide or `repo`-classic scope. The agent runs LLM-generated code; the
token is the one credential it holds, so keep its blast radius to one repo.

> **A note on self-triggering.** The pipeline posts its own PR comments using this token.
> If you later comment as the *same* account that owns the token, the pipeline treats it
> as its own voice and ignores it. To drive a fix round by hand, comment from a
> **different** GitHub account.

## Option B — recommended (External Secrets + AWS Secrets Manager)

Keeps the credential in Secrets Manager, rotatable, never on your laptop.

```bash
# Terraform already created the empty secret (var.github_secret_name). Add the value.
aws secretsmanager put-secret-value \
  --secret-id agent-sandbox/github \
  --secret-string '{"token":"ghp_...","webhook-secret":"..."}' \
  --region us-west-2
```

`task demo-*` then renders three ExternalSecrets (`templates/05-externalsecret-github.yaml`),
which create the three Secrets above from that entry. This is the path to use for anything
beyond a demo. [`docs/MANUAL-STEPS.md` §1](../../docs/MANUAL-STEPS.md) has a version that
keeps the token out of your shell history.

## The GitHub webhook

Point your repo's webhook at the EventSource:

- **Payload URL:** the ingress/load balancer fronting the `argo-events` EventSource
- **Content type:** `application/json`
- **Secret:** the `webhook-secret` value from above
- **Events:** Issues, Issue comments, Pull requests, Pull request reviews

```bash
# Find the endpoint after the substrate is installed
kubectl get svc,ingress -n argo-events
```

## Beyond a demo: use a GitHub App

A personal token is a single point of trust and shares one rate limit across every
agent, gate, and status update. For real use — especially many repositories — register a
**GitHub App** instead: per-installation tokens, per-repository permissions, and its own
rate limit. The manifests only care that the Secret contains a usable `token`, so
swapping in an App installation token requires no pipeline change.

## Verify

```bash
kubectl get secret dark-factory-github -n argo-events
# Should list keys: token, webhook-secret  (values stay opaque)
kubectl get secret dark-factory-github -n argo-events -o jsonpath='{.data}' | tr ',' '\n'
```
