# Security Policy

## Reporting a vulnerability

**Do not open a public GitHub issue for security problems.**

If you discover a potential security issue in this project, please notify AWS Security via
[vulnerability-reporting@amazon.com](mailto:vulnerability-reporting@amazon.com) or the
[AWS Vulnerability Reporting page](https://aws.amazon.com/security/vulnerability-reporting/).

## Security model of this blueprint

This blueprint deliberately runs **untrusted, LLM-generated code**. Understand these boundaries
before adapting it:

### What is isolated
- **Agent code runs inside a micro-VM with its own kernel** — Kata (Cloud Hypervisor / QEMU /
  Firecracker) or an AWS Lambda MicroVM. It is never a shared-kernel container.
- **The agent has no Kubernetes credentials.** No ServiceAccount token is projected into the
  sandbox, so the agent cannot talk to the API server. It reports progress only through GitHub.
- **NetworkPolicy restricts sandbox egress.** The agent can reach the model endpoint and GitHub;
  it cannot reach the control plane, the instance metadata service, or arbitrary cluster services.
- **Only one pipeline step holds cluster write access** (the deploy test), and it operates in an
  ephemeral namespace that is torn down afterwards.

### What you must supply safely
- **GitHub credentials are yours to scope.** The blueprint reads a token from a Kubernetes Secret
  you create; it is never committed. Scope it to the single target repository. For anything beyond
  a demo, use a **GitHub App** with per-repository permissions instead of a personal token.
- **Least-privilege IAM.** The provided roles are scoped to what each component calls. Review them
  against your own account boundaries before use.
- **This is a blueprint, not a hardened product.** It has no multi-tenancy, quota enforcement, or
  admission control. See `docs/ROADMAP.md` for the gaps that matter at scale.

### Reviewing agent output
Merges require an explicit human approval event. Automated gates (hidden-scenario holdout, deploy
test, security and DevOps reviewers) are **advisory signals to a human**, not a substitute for
review. Do not point this at a repository where an unreviewed merge would be harmful.
