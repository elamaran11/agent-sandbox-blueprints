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
ENTRYPOINT="${ENTRYPOINT:-$HERE/../../examples/dark-factory-lambda/agent/entrypoint.js}"

if [[ ! -f "$ENTRYPOINT" ]]; then
  echo "ERROR: agent entrypoint not found at: $ENTRYPOINT" >&2
  echo "       Set ENTRYPOINT=/path/to/entrypoint.js" >&2
  exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp "$HERE/Dockerfile" "$HERE/hook-server.js" "$ENTRYPOINT" "$STAGE/"

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
