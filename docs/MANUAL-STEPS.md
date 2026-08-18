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

## 2. Expose and register the GitHub webhook

**Why this cannot be automated:** the webhook must point at an address that does not
exist until the cluster does, and pointing GitHub at your cluster is a deliberate act
on a repo you own.

### 2a. Give the EventSource a public address

`task demo-*` creates a `dark-factory-webhook` Service of type `LoadBalancer`
(`examples/_shared/templates/44-eventsource-service.yaml`).

> Two things that are NOT true, both verified on a live cluster:
> * Setting `spec.service.type: LoadBalancer` on the **EventSource** does nothing —
>   the Argo Events controller reads only `spec.service.ports` and always creates a
>   ClusterIP. Hence the separate Service.
> * A plain `LoadBalancer` Service does **not** get an NLB for free. On EKS 1.36 the
>   in-tree cloud LoadBalancer support is gone, so without the **AWS Load Balancer
>   Controller** the Service sits at `EnsuringLoadBalancer` with no address forever.

So pick one:

**Option A — install the AWS Load Balancer Controller** (what OAP does). Then:

```bash
kubectl get svc dark-factory-webhook -n argo-events \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

**Option B — no load balancer.** Set `trigger.argoEvents.serviceType=ClusterIP` (the
Service is then not rendered) and expose the EventSource yourself — an SSH/ngrok-style
tunnel to `dark-factory-github-eventsource-svc:12000`, or run the pipeline without
GitHub events by submitting the workflow directly:

```bash
kubectl create -n argo -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata: { generateName: df-run- }
spec:
  workflowTemplateRef: { name: df-run }
  arguments:
    parameters:
      - { name: issue-number, value: "1" }
      - { name: issue-id,     value: "1" }
      - { name: repo,         value: "your-org/your-repo" }
      - { name: issue-title,  value: "Add a health endpoint" }
      - { name: base-branch,  value: "main" }
EOF
```

That exercises the whole pipeline (claim → coder → PR) without a public endpoint, and
is the fastest way to see a run end to end.

### 2b. Register it on the repo

In the target repo → **Settings → Webhooks → Add webhook**:

| Field | Value |
|---|---|
| Payload URL | `http://<address>:12000/dark-factory` |
| Content type | `application/json` |
| Secret | the `webhook-secret` from step 1 |
| Events | Issues, Pull requests, Pull request reviews, Issue comments |

Argo Events can self-register this (`active: true` on the EventSource) if the PAT has
`admin:repo_hook`. A fine-grained token scoped to one repo usually does not, hence the
manual path.

> Plain HTTP sends the HMAC-signed payload unencrypted. Fine for a demo on a throwaway
> repo; terminate TLS for anything real.

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

## 5. Set up the review agents (optional, but this is the interesting part)

Two independent reviewers run **outside** the sandbox — the coder never grades its own
work. Both are **off by default** (`enabled: false`) because they are a limited preview
and not available in every account. The pipeline runs fine without them: the gate steps
become no-ops and report success.

> If a run shows `devops-gate Succeeded` but no `aws-devops-agent/...` check on the PR,
> the agent was disabled — not broken. That is the no-op path.

| | Gates via | Verdict appears as |
|---|---|---|
| **DevOps Agent** (release readiness, runs first) | its GitHub App check-run | check `aws-devops-agent/release-readiness-review` |
| **Security Agent** (narrow/strict, runs second) | AWS API polled by the pipeline | commit status `dark-factory/security` |

### 5a. DevOps Agent

1. Install the **AWS DevOps Agent GitHub App** on the target repo.
2. In the console, create/choose an **Agent Space** and **connect the repo** to it.
   This one-time connect cannot be scripted, and cannot be done from the
   credential-less sandbox (no browser, no Midway).
3. Enable it:

```yaml
devopsAgent:
  enabled: true
  gate: check        # wait for the App's check-run (default, native)
  waitSeconds: 900
```

`gate: label` is the fallback if you drive the review some other way — the pipeline
then waits for a coder-applied label instead of a check-run.

### 5b. Security Agent

This one needs AWS resources the blueprint does **not** create for you:

| Needed | Value | Notes |
|---|---|---|
| IRSA role | `securityAgent.irsaRoleArn` | the review step assumes it |
| Service role | `securityAgent.serviceRoleArn` | the agent service assumes it |
| S3 diff bucket | `securityAgent.diffBucket` | the PR diff is staged here for review |
| Identity Center instance | `securityAgent.idcInstanceArn` | `arn:aws:sso:::instance/ssoins-...` |
| Agent Space + Application IDs | Secret named by `securityAgent.secretName` | see below |

**Known gap:** OAP ships a PreSync Job that finds-or-creates the Agent Space and writes
its IDs into that Secret. This blueprint does **not** port it, so the Secret must
already exist — create the space in the console and record its IDs:

```bash
kubectl create secret generic dark-factory-securityagent -n argo \
  --from-literal=spaceId=<agent-space-id> \
  --from-literal=appId=<application-id>
```

Then enable it:

```yaml
securityAgent:
  enabled: true
  region: us-west-2
  spaceName: dark-factory
  irsaRoleArn: arn:aws:iam::<acct>:role/<your-irsa-role>
  serviceRoleArn: arn:aws:iam::<acct>:role/service-role/<your-service-role>
  diffBucket: <your-diff-bucket>
  idcInstanceArn: arn:aws:sso:::instance/ssoins-...
  blockLevel: medium      # findings at/above this severity fail the merge gate
```

Put these in the **gitignored** `examples/dark-factory-*/values.yaml`, never in a
committed file — they are account-specific and `task lint:leaks` will reject them.

### 5c. Verify a run actually used them

```bash
# the PR's combined status should list BOTH agent results
gh pr checks <pr-number> --repo <org>/<repo>
```

A run with both agents live looks like this (verified on a real PR):

```
dark-factory/implementation                success  implemented, built + tests green
dark-factory/holdout                       success  holdout 8/8 (100%) — gate passed
dark-factory/security                      success  security: no findings
aws-devops-agent/release-readiness-review  success  Release readiness review: change approved
```

Ordering is deliberate (AI-DLC): DevOps first for broad release readiness, then the
Security Agent for the narrow strict pass. A single consolidated verdict is written back
so mixed signals cannot leave a PR ambiguous.

## Not manual — common misconceptions

| Looks manual | Actually |
|---|---|
| Cluster name, node role, git repo in manifests | Substituted by `task kata`/`task lambda` from Terraform outputs |
| Agent image URIs in values | Injected by `task demo` from `coder_ecr_urls` |
| Bifrost address (a ClusterIP, not DNS) | Looked up live by `task demo` |
| The three GitHub Secrets | Created by ESO from step 1 |
| Default StorageClass | `infrastructure/terraform/storage.tf` |
