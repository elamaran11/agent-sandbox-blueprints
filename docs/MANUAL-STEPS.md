# Manual steps

Everything in this blueprint is Terraform or GitOps except the items below. Each one
is here for a reason, stated — not because it was left unfinished.

If you are looking for "why isn't the GitHub token just in values?", that is
[step 1](#1-put-the-github-credential-in-secrets-manager-once).

---

## 1. Put the GitHub credential in Secrets Manager (once)

**Why this cannot be automated:** it is a credential. It cannot live in git, and a
values file is in git. Terraform does not take it either — a value passed to a
Terraform resource is written to state in plaintext.

So the credential enters the system exactly once, by hand. **Everything after that is
automated:**

```
you, ONCE ──▶ Secrets Manager: dark-factory/github
                 │   ClusterSecretStore, read via EKS Pod Identity (no static keys)
                 ▼
              ExternalSecret ×3  ──▶  k8s Secret in:
                                        argo                  key: token
                                        argo-events           keys: token, webhook-secret
                                        agent-sandbox-system  key: gh-token
                 │
                 ▼
              mounted 0400 into the sandbox at /etc/secrets/gh-token
```

Git and values carry only the **reference** — the secret id and the key names — never
the value. Rotation is a Secrets Manager update; ESO re-syncs within
`github.externalSecret.refreshInterval` (1h by default). A cluster rebuild re-creates
all three Secrets with no human involved.

```bash
# Fine-grained PAT scoped to the single target repo. See SECRETS.md for scopes.
read -rs GH_TOKEN                       # -s: not echoed, not in shell history
WEBHOOK_SECRET="$(openssl rand -hex 20)"

aws secretsmanager create-secret \
  --name dark-factory/github \
  --region us-west-2 \
  --secret-string "$(python3 -c 'import json,os,sys;print(json.dumps({"token":sys.argv[1],"webhook-secret":sys.argv[2]}))' "$GH_TOKEN" "$WEBHOOK_SECRET")"

echo "Webhook secret (paste into GitHub in step 2): $WEBHOOK_SECRET"
unset GH_TOKEN
```

Terraform creates the empty secret container and the read permission
(`infrastructure/terraform/secrets.tf`); you supply only the value.

> The secret id must match `github.externalSecret.secretsManagerKey` in the example
> values and `var.github_secret_name` in Terraform. All three default to
> `dark-factory/github`.

**Verify without printing anything sensitive:**

```bash
kubectl get externalsecret -A          # all three should be SecretSynced
kubectl get secret dark-factory-github -n agent-sandbox-system -o jsonpath='{.data}' \
  | python3 -c 'import json,sys;print(list(json.load(sys.stdin).keys()))'   # ['gh-token']
```

---

## 2. Register the GitHub webhook

**Why this cannot be automated:** the webhook has to point at an address that does not
exist until the cluster does, and pointing GitHub at your cluster is a deliberate act
on a repo you own.

`task demo-*` exposes the EventSource as a `LoadBalancer` (an NLB — this blueprint
installs no ingress controller). Get the address:

```bash
kubectl get svc -n argo-events -l 'eventsource-name=dark-factory-github' \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}'
```

Then in the target repo → **Settings → Webhooks → Add webhook**:

| Field | Value |
|---|---|
| Payload URL | `http://<nlb-hostname>:12000/dark-factory` |
| Content type | `application/json` |
| Secret | the `webhook-secret` from step 1 |
| Events | Issues, Pull requests, Pull request reviews, Issue comments |

Argo Events can self-register this (`active: true` in the EventSource) if the PAT has
`admin:repo_hook`. A fine-grained token scoped to one repo usually does not, hence the
manual path.

> Plain HTTP on the NLB is fine for a demo but sends the HMAC-signed payload
> unencrypted. For anything real, terminate TLS — an ACM cert on the NLB, or add an
> ingress controller and use the ALB pattern OAP uses.

---

## 3. Build and push the agent images

**Why this is not automated:** the blueprint does not ship CI that pushes to your
account, and it should not.

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text); REGION=us-west-2
aws ecr get-login-password --region $REGION \
  | docker login --username AWS --password-stdin $ACCT.dkr.ecr.$REGION.amazonaws.com

CODER="$ACCT.dkr.ecr.$REGION.amazonaws.com/agent-sandbox/dark-factory-coder"
MVM="$ACCT.dkr.ecr.$REGION.amazonaws.com/agent-sandbox/dark-factory-coder-microvm"

# Kata pods are x86_64; Lambda MicroVM is ARM64-only. Two images, two repos.
docker build --platform linux/amd64 -t "${CODER}:v0.1.0" -t "${CODER}:latest" examples/_shared/agent
docker build --platform linux/arm64 -t "${MVM}:v0.1.0"   -t "${MVM}:latest"   examples/_shared/agent
docker push "${CODER}:v0.1.0"; docker push "${CODER}:latest"
docker push "${MVM}:v0.1.0";   docker push "${MVM}:latest"
```

In zsh use `${CODER}:latest`, not `$CODER:latest` — `:l` is a zsh parameter modifier
and silently mangles the tag into `...coderatest`.

`task kata` reads the repo URL from the `coder_ecr_urls` Terraform output, so nothing
needs editing — but build **before** `task kata`, or warm-pool members land in
`ImagePullBackOff`.

---

## 4. Publish the MicroVM code artifact (Lambda substrate only)

**Why this is not automated:** Lambda MicroVM builds the VM image from a ZIP in S3, and
it only rebuilds when `codeArtifact.uri` **changes**. Overwriting the same key is a
silent no-op — the classic "my fix didn't take effect" bug — so the revision bump is a
deliberate human decision.

```bash
./lambda-microvm/image/publish.sh r1      # then set codeArtifactUri to the printed s3:// key
```

---

## 5. Connect the review agents (optional)

The AWS Security Agent and DevOps Agent are a limited preview and need a one-time
console step (Agent Space ↔ repo connection) that cannot be scripted or done from the
credential-less sandbox. Both default to `enabled: false`; the pipeline runs without
them. See `docs/PREREQUISITES.md`.

---

## Not manual — common misconceptions

| Looks manual | Actually |
|---|---|
| Cluster name, node role, git repo in manifests | Substituted by `task kata`/`task lambda` from Terraform outputs |
| Agent image URIs in values | Injected by `task demo` from `coder_ecr_urls` |
| Bifrost address (a ClusterIP, not DNS) | Looked up live by `task demo` |
| The three GitHub Secrets | Created by ESO from step 1 |
| Default StorageClass | `infrastructure/terraform/storage.tf` |
