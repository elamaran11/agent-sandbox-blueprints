# Secrets

Both examples need the same two GitHub credentials. **Neither ever goes in git or in a
values file** — manifests reference only the Secret's *name* (`github.secretName`).

| Key | What it is |
|---|---|
| `token` | A GitHub token the agent uses to clone, push a branch, open a PR, and comment |
| `webhookSecret` | The HMAC secret you set on the GitHub webhook, so the EventSource can verify deliveries are genuine |

## Option A — quickstart (`kubectl`)

Fine for a demo on a throwaway repo.

```bash
# A random HMAC secret for the webhook; you will paste this into GitHub below.
WEBHOOK_SECRET="$(openssl rand -hex 20)"

kubectl create namespace argo-events --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic dark-factory-github \
  --namespace argo-events \
  --from-literal=token="ghp_your_token_here" \
  --from-literal=webhookSecret="$WEBHOOK_SECRET"

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
aws secretsmanager create-secret \
  --name dark-factory/github \
  --secret-string '{"token":"ghp_...","webhookSecret":"..."}' \
  --region us-west-2
```

Then apply `_shared/manifests/05-externalsecret-github.yaml`, which materializes the
same Secret name from that Secrets Manager entry. This is the path to use for anything
beyond a demo.

## The GitHub webhook

Point your repo's webhook at the EventSource:

- **Payload URL:** the ingress/load balancer fronting the `argo-events` EventSource
- **Content type:** `application/json`
- **Secret:** the `webhookSecret` value from above
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
# Should list keys: token, webhookSecret  (values stay opaque)
kubectl get secret dark-factory-github -n argo-events -o jsonpath='{.data}' | tr ',' '\n'
```
