# Contributing

Thanks for your interest. This is a **blueprint** — the bar for a change is "does this make the
pattern easier to run and understand," not "does this add a feature."

## Ground rules

1. **Nothing real is committed.** Config lives in `*.example.*` templates; the files people actually
   edit (`terraform.tfvars`, `values.yaml`) are gitignored. Never commit a token, account id, ARN
   from a live account, or a `.terraform/` directory.
2. **Run `task lint` before you push.** It checks `terraform fmt`/`validate` and scans tracked files
   for credentials.
3. **Keep the three substrates independent.** A change to `kata/` must not require
   `lambda-microvm/` or `agentcore/`, and so on for each pair. Each must remain separately
   deployable.
4. **Document gotchas, not just fixes.** If you hit something non-obvious, add it to
   `docs/TROUBLESHOOTING.md` with the symptom *and* the cause. That file is the most valuable thing
   here for someone reproducing this.
5. **Small, verifiable commits.** One logical change per commit, with a message that says *why*.

## Development flow

```bash
task lint                      # fmt, validate, secret scan
task up                        # bring up a cluster to test against
task kata      # and/or        # install a substrate
task lambda
task agentcore
task demo-kata # and/or        # run a pipeline end to end
task demo-lambda
task demo-agentcore
task down                      # always clean up — this costs real money
```

## What to test before opening a PR

| Change touches | Verify |
|---|---|
| `infrastructure/terraform/` | `task lint:tf`, then `task up` on a throwaway account |
| `infrastructure/gitops/` | ArgoCD apps reach `Synced/Healthy` |
| `kata/` | A pod runs under each RuntimeClass you touched (`kata-clh`, `kata-qemu`, `kata-fc`) |
| `lambda-microvm/` | A `Microvm` reaches `RUNNING`, and is `TERMINATED` after teardown — check with `aws lambda-microvms get-microvm`, **not** the CR status (it is stale) |
| `agentcore/` | The `AgentRuntime` reaches `READY` on `platformVersion: V2` — check with `aws bedrock-agentcore-control get-agent-runtime`, **not** the KRO status (it lags AWS after updates). `invoke-agent-runtime` returns 202 and `stop-runtime-session` 200 on a fresh session id |
| `examples/` | A labeled issue produces a PR, and the sandbox is cleaned up afterwards |

## Reporting problems

Open an issue with: what you ran, the substrate, the phase it failed in, and the relevant
`kubectl`/Argo output. If it is security-related, follow [SECURITY.md](SECURITY.md) instead.

## Licensing

By contributing, you agree your contributions are licensed under the [MIT-0](LICENSE) license.
