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

## 5. Set up the review agents (step by step)

Two independent reviewers run **outside** the sandbox — the coder never grades its own
work. Both are **off by default** (`enabled: false`) because they need account-level
onboarding you must do once. The pipeline runs fine without them: the gate steps become
no-ops and report success.

> If a run shows `devops-gate Succeeded` but no `aws-devops-agent/...` check on the PR,
> the agent was **disabled**, not broken. That is the no-op path — the single most
> confusing thing about this pipeline.

| | Reviews | Gates via | Verdict appears as |
|---|---|---|---|
| **DevOps Agent** (first) | broad release readiness | its GitHub App check-run | check `aws-devops-agent/release-readiness-review` |
| **Security Agent** (second) | narrow, strict | AWS API polled by the pipeline | commit status `dark-factory/security` |

Ordering is deliberate (the AI-DLC model): broad readiness first, then the strict
security pass. A single consolidated verdict is written back so mixed signals cannot
leave a PR ambiguous.

---

### 5a. Create the Agent Space (shared by both agents)

An **Agent Space** is the logical container defining an agent's access scope. Both
agents live in one.

1. **Create the space role** — the IAM role the DevOps Agent service principal assumes
   inside the space:
   [Create the DevOps Agent space role](https://docs.aws.amazon.com/devopsagent/latest/userguide/getting-started-with-aws-devops-agent-cli-onboarding-guide.html)
2. **Create the Agent Space** — name it, set the primary AWS account and operator
   access:
   [Creating an Agent Space](https://docs.aws.amazon.com/devopsagent/latest/userguide/getting-started-with-aws-devops-agent-creating-an-agent-space.html)
   Use the same name you put in `securityAgent.spaceName` (default `dark-factory`).
3. Verify it in the console per the "Verifying your Agent Space setup" section of that
   page before continuing — a half-created space fails later in ways that look like
   permissions problems.

### 5b. Register GitHub, then connect the repo

Two distinct steps, and the second is the one people miss:

1. **Account-level registration** — register your GitHub user / org / Enterprise Server
   instance once for the account.
2. **Connect the specific repo to the Agent Space**, and enable
   **Code Review and Automated Testing** so pull requests trigger release-readiness
   reviews:
   [Connecting repositories to an Agent Space](https://docs.aws.amazon.com/devopsagent/latest/userguide/connecting-to-cicd-pipelines-connecting-github.html)

Account registration alone does **nothing** for a given repo — without the per-repo
connection no check-run is ever posted, and `devops-gate` waits out its
`waitSeconds` and fails with no explanation on the PR.

> This connection cannot be scripted, and cannot be done from the sandbox: the coder VM
> is credential-less with no browser and no Midway. That is why it is in this document
> and not in Terraform.

### 5c. Enable the DevOps Agent

```yaml
devopsAgent:
  enabled: true
  gate: check            # wait for the App's check-run (default, native)
  checkRunName: "aws-devops-agent/release-readiness-review"
  waitSeconds: 900
  clearVerdicts: ["Safe to Release", "Proceed with Caution"]
```

`clearVerdicts` is what counts as a pass — any other verdict blocks the merge gate.
`gate: label` is the fallback if you drive the review another way; the pipeline then
waits for a coder-applied label instead of a check-run.

### 5d. Enable the Security Agent

This one needs AWS resources the blueprint does **not** create for you:

| Value | What it is |
|---|---|
| `securityAgent.irsaRoleArn` | role the in-cluster review step assumes |
| `securityAgent.serviceRoleArn` | role the agent service assumes (usually under `/service-role/`) |
| `securityAgent.diffBucket` | S3 bucket the PR diff is staged into for review |
| `securityAgent.idcInstanceArn` | `arn:aws:sso:::instance/ssoins-...` |
| `securityAgent.secretName` | Secret holding the space + application IDs |

**Known gap:** OAP ships a PreSync Job that finds-or-creates the Agent Space and writes
its IDs into that Secret. This blueprint does **not** port it, so create the Secret
yourself after 5a:

```bash
kubectl create secret generic dark-factory-securityagent -n argo \
  --from-literal=spaceId=<agent-space-id> \
  --from-literal=appId=<application-id>
```

Then:

```yaml
securityAgent:
  enabled: true
  region: us-west-2
  spaceName: dark-factory          # must match the space from 5a
  irsaRoleArn: arn:aws:iam::<acct>:role/<irsa-role>
  serviceRoleArn: arn:aws:iam::<acct>:role/service-role/<service-role>
  diffBucket: <diff-bucket>
  idcInstanceArn: arn:aws:sso:::instance/ssoins-...
  blockLevel: medium               # findings at/above this severity block the gate
  pollTimeoutSeconds: 900
```

Put all of it in the **gitignored** `examples/dark-factory-*/values.yaml` — never a
committed file. These are account-specific and `task lint:leaks` will reject them.

### 5e. Verify a run really used both agents

```bash
gh pr checks <pr-number> --repo <org>/<repo>
```

A run with both agents live looks like this (from a real PR on this blueprint):

```
aws-devops-agent/release-readiness-review  pass   Release readiness review: change approved
dark-factory/security                      pass   security: no findings
dark-factory/deploy-test                   pass   terraform validate passed
dark-factory/holdout                       pass   not applicable — no hidden scenarios match
dark-factory/implementation                pass   implemented, built + tests green
```

And a genuine block looks like this — the DevOps Agent caught a real regression where
the coder deleted an existing bucket policy:

```
aws-devops-agent/release-readiness-review  fail   Release readiness review: change blocked
```

with a `critical` inline finding on the PR. That is the system working: two reviewers
disagreeing is the point, and the Security Agent passed the same change.

### 5f. When a verdict blocks

Comment the finding on the PR and `df-iterate` re-runs the coder with it as a revision
note. `iterate.maxIterations` (default 3) caps the loop so it cannot spin.

> Requires `iterate.identityGuard: false` (the default) when the factory shares a PAT
> with the repo owner — otherwise your own comment is read as the factory
> self-triggering and the round is silently skipped.

---

## 6. Decoupling from another stack (before you tear one down)

This blueprint is self-contained, but **account-level** resources can be shared with a
larger platform in the same account (e.g. an OAP hub/spoke). If that stack is destroyed,
anything it *owns* goes with it — and a shared credential disappearing looks like a
broken agent, not a teardown side effect.

### The one that breaks everything: the GitHub secret

Namespaced under the project (`agent-sandbox/github`) so no other stack owns it. If you
inherited a shared one, duplicate it into your own before tearing the other stack down:

```bash
# copy the value into a blueprint-owned secret (value never printed)
V=$(aws secretsmanager get-secret-value --secret-id <shared-secret-id> \
      --region us-west-2 --query SecretString --output text)
aws secretsmanager create-secret --name agent-sandbox/github --region us-west-2 \
  --description "GitHub PAT + webhook HMAC for agent-sandbox-blueprints" \
  --secret-string "$V"; unset V

# point Terraform + the examples at it (already the defaults)
#   terraform: var.github_secret_name       = "agent-sandbox/github"
#   examples:  github.externalSecret.secretsManagerKey = agent-sandbox/github
terraform apply -var-file=terraform.tfvars     # repoints ESO's read policy
task demo-kata && task demo-lambda             # re-render the ExternalSecrets

# verify: all three Ready, all reading the NEW id
kubectl get externalsecret -A \
  -o custom-columns='NS:.metadata.namespace,READY:.status.conditions[0].status,KEY:.spec.data[0].remoteRef.key'
```

`create_github_secret = false` keeps Terraform from *owning* a secret it did not create,
so `task down` here can never delete it. Set it `true` only if you want this stack to own
the lifecycle.

### The other three, and how exposed you are

| Shared thing | Blueprint use | If the other stack deletes it |
|---|---|---|
| Security Agent IRSA role, service role, diff bucket | `dark-factory/security` gate | Gate breaks. Recreate them, or set `securityAgent.enabled: false` — the pipeline still runs |
| Agent Space + repo connection | Both agent reviews | Redo [§5a–5b](#5a-create-the-agent-space-shared-by-both-agents). Account-level, not owned by any one cluster |
| A `MicrovmImage` sharing a name | Lambda substrate | **Not exposed** — image/bucket/roles are keyed to the cluster name (see ROADMAP gap 5) |
| ECR repos | Agent images | **Not exposed** — namespaced under `project_name` |

### Before destroying the other stack

```bash
# 1. does IT own your secret? if this lists it, its destroy will delete it
cd <other-stack>/terraform && terraform state list | grep -i secretsmanager

# 2. confirm nothing here still points at the other stack
grep -rn 'dark-factory/github' examples/ infrastructure/ | grep -v ROADMAP

# 3. after teardown, re-verify this blueprint
kubectl get externalsecret -A          # 3x Ready=True
```

Then run one labelled issue end to end. If the coder fails GitHub auth, the secret went
with the teardown — restore it from the duplicate above.

## Not manual — common misconceptions

| Looks manual | Actually |
|---|---|
| Cluster name, node role, git repo in manifests | Substituted by `task kata`/`task lambda` from Terraform outputs |
| Agent image URIs in values | Injected by `task demo` from `coder_ecr_urls` |
| Bifrost address (a ClusterIP, not DNS) | Looked up live by `task demo` |
| The three GitHub Secrets | Created by ESO from step 1 |
| Default StorageClass | `infrastructure/terraform/storage.tf` |
