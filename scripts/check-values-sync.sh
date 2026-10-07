#!/usr/bin/env bash
# Fail if an example's defaults.yaml drifts from examples/_shared/values.yaml on
# the keys they share.
#
# Each example carries its own copy of the shared values tree (ROADMAP gap #6).
# This keeps the copies honest: strip the keys that legitimately differ per
# example, normalise both sides to sorted JSON with yq, and diff.
#
# Keys stripped on BOTH sides:
#   agentcore            substrate-only block in the AgentCore example
#   dark-factory-shared  subchart-scope mirror, never in _shared itself
# Stripped for the AgentCore example only:
#   microvm              Lambda's block; AgentCore has no reason to carry it
#
# Usage: scripts/check-values-sync.sh            (from the repo root)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
command -v yq >/dev/null || { echo "yq (mikefarah, v4) is required" >&2; exit 2; }

shared=examples/_shared/values.yaml
examples=(dark-factory-kata dark-factory-lambda dark-factory-agentcore)

normalise() { # file  drop-keys...
  local file=$1; shift
  local expr='.'
  for k in "$@"; do expr+=" | del(.\"$k\")"; done
  yq -o=json -P "$expr" "$file" | yq -o=json 'sort_keys(..)'
}

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
for ex in "${examples[@]}"; do
  drop=(agentcore dark-factory-shared)
  [ "$ex" = dark-factory-agentcore ] && drop+=(microvm)
  if diff -u \
       <(normalise "$shared" "${drop[@]}") \
       <(normalise "examples/$ex/defaults.yaml" "${drop[@]}") \
       > "$tmp/$ex.diff"; then
    echo "✓ examples/$ex/defaults.yaml matches _shared on common keys"
  else
    echo "✗ examples/$ex/defaults.yaml differs from _shared:"
    sed 's/^/    /' "$tmp/$ex.diff"
    fail=1
  fi
done
exit $fail
