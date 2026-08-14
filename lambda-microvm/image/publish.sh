#!/usr/bin/env bash
# Publish the MicroVM agent code artifact to S3.
#
#   ./publish.sh [revision]
#
# AWS Lambda MicroVM does not take a container image reference. It builds the VM
# image itself from a ZIP in S3 containing a Dockerfile plus the app. That
# Dockerfile pulls the agent image from ECR as its base layer, which is why the
# MicrovmImage build role keeps ecr:Get*/BatchGetImage.
#
# THE GOTCHA THIS SCRIPT EXISTS FOR
#   Overwriting the SAME S3 key does NOT trigger a rebuild. The MicrovmImage only
#   rebuilds when spec.codeArtifact.uri CHANGES. So every publish gets a NEW
#   versioned key, and you must bump codeArtifactUri to match. Silently editing
#   the artifact in place is the classic "my fix didn't take effect" bug.
set -euo pipefail

REVISION="${1:-r1}"
REGION="${REGION:-us-west-2}"
IMAGE_NAME="${IMAGE_NAME:-coder}"
BUCKET="${BUCKET:-${IMAGE_NAME}-microvm-artifacts}"
KEY="${IMAGE_NAME}-${REVISION}.zip"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The agent entrypoint lives with the example that uses it; the MicroVM image is
# the same agent wrapped in the hook-server this runtime requires.
ENTRYPOINT="${ENTRYPOINT:-$HERE/../../examples/_shared/agent/entrypoint.js}"

if [[ ! -f "$ENTRYPOINT" ]]; then
  echo "ERROR: agent entrypoint not found at: $ENTRYPOINT" >&2
  echo "       Set ENTRYPOINT=/path/to/entrypoint.js" >&2
  exit 1
fi

# Resolve the ECR base image the staged Dockerfile builds FROM.
#
# Lambda builds the VM image from this ZIP with NO build args, so `ARG CODER_IMAGE`
# has to arrive as a concrete value inside the Dockerfile we ship. The committed
# Dockerfile deliberately carries no default (a baked ECR URI would point a fork at
# an account it cannot pull from), so resolve it here: explicit env wins, otherwise
# read the terraform output.
TF_DIR="${TF_DIR:-$HERE/../../infrastructure/terraform}"
if [[ -z "${CODER_IMAGE:-}" ]]; then
  # coder_microvm is the ARM64 repo. Lambda MicroVM is ARM_64-only, and ecr.tf
  # creates a separate repo for it precisely so the two arches never collide on
  # one tag.
  CODER_REPO="$(terraform -chdir="$TF_DIR" output -json coder_ecr_urls 2>/dev/null \
    | python3 -c 'import json,sys;print(json.load(sys.stdin).get("coder_microvm",""))' 2>/dev/null || echo "")"
  if [[ -n "$CODER_REPO" ]]; then
    CODER_IMAGE="${CODER_REPO}:${CODER_TAG:-latest}"
  fi
fi

if [[ -z "${CODER_IMAGE:-}" ]]; then
  echo "ERROR: could not determine the base coder image." >&2
  echo "       Set it explicitly:" >&2
  echo "         CODER_IMAGE=<acct>.dkr.ecr.<region>.amazonaws.com/<repo>:<tag>-arm64 ./publish.sh" >&2
  echo "       or run from a tree where terraform has been applied (coder_ecr_urls output)." >&2
  exit 1
fi

# Lambda MicroVM is ARM_64-only — an amd64 base builds fine and then fails to boot.
# Verify the manifest arch rather than trusting the tag name.
ARCH="$(aws ecr batch-get-image --region "$REGION" \
          --repository-name "$(printf '%s' "${CODER_IMAGE%%:*}" | cut -d/ -f2-)" \
          --image-ids imageTag="${CODER_IMAGE##*:}" \
          --query 'images[0].imageManifest' --output text 2>/dev/null \
        | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("architecture",""))' 2>/dev/null || echo "")"
if [[ -n "$ARCH" && "$ARCH" != "arm64" ]]; then
  echo "WARNING: $CODER_IMAGE is $ARCH, but Lambda MicroVM is ARM_64-only." >&2
  echo "         It will build and then fail to start." >&2
fi

echo "base image: $CODER_IMAGE"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp "$HERE/Dockerfile" "$HERE/hook-server.js" "$ENTRYPOINT" "$STAGE/"

# Bake the resolved base into the STAGED copy only; the committed file stays clean.
python3 - "$STAGE/Dockerfile" "$CODER_IMAGE" <<'PY'
import sys
path, image = sys.argv[1], sys.argv[2]
with open(path) as f:
    text = f.read()
needle = "\nARG CODER_IMAGE\n"
if needle not in text:
    sys.exit("ERROR: expected a bare 'ARG CODER_IMAGE' line in the Dockerfile")
with open(path, "w") as f:
    f.write(text.replace(needle, f"\nARG CODER_IMAGE={image}\n"))
PY

( cd "$STAGE" && zip -q -r artifact.zip Dockerfile hook-server.js entrypoint.js )

if ! aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
  echo "NOTE: bucket s3://$BUCKET does not exist yet."
  echo "      It is created by the KRO graph (MicrovmSandbox) as \${image.name}-microvm-artifacts."
  echo "      Apply the substrate first ('task lambda'), then re-run this script."
  exit 1
fi

aws s3 cp "$STAGE/artifact.zip" "s3://${BUCKET}/${KEY}" --region "$REGION"

cat <<EOF

✓ published s3://${BUCKET}/${KEY}

NEXT — bump the artifact URI so the image actually rebuilds:

  codeArtifactUri: "s3://${BUCKET}/${KEY}"

Set it in your examples/dark-factory-lambda/values.yaml (or the substrate values)
and let ArgoCD sync. Reusing a previous key will NOT rebuild the image.

Watch the rebuild:
  kubectl get microvmimage -A -w
EOF
