#!/usr/bin/env bash
# Publish the arm64 coder host to ECR. Use the resulting immutable digest URI
# in agentcore.image.uri; updating a tag alone cannot update an ACK runtime.
#   REGION=us-west-2 IMAGE_NAME=<ecr-repository-uri> CODER_IMAGE=<arm64-base> ./publish.sh r1
set -euo pipefail

REVISION="${1:-r1}"
REGION="${REGION:-us-west-2}"
IMAGE_NAME="${IMAGE_NAME:?set IMAGE_NAME to the full ECR repository URI (without tag)}"
CODER_IMAGE="${CODER_IMAGE:?set CODER_IMAGE to the arm64 coder base image URI}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="${IMAGE_NAME%%/*}"

if [[ "$IMAGE_NAME" != *.dkr.ecr."$REGION".amazonaws.com/* ]]; then
  echo "ERROR: IMAGE_NAME must be an ECR repository URI in $REGION" >&2
  exit 1
fi
if [[ ! "$REVISION" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
  echo "ERROR: revision must be an ECR-safe tag suffix" >&2
  exit 1
fi

aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"
TAG="${IMAGE_NAME}:agentcore-${REVISION}"
docker buildx build --platform linux/arm64 --build-arg "CODER_IMAGE=$CODER_IMAGE" \
  -t "$TAG" --push "$HERE"

# ECR reports the registry digest after push. Never use the local image ID:
# multi-platform builds may have a different local vs remote manifest digest.
REPOSITORY="${IMAGE_NAME#*/}"
DIGEST="$(aws ecr describe-images --region "$REGION" --repository-name "$REPOSITORY" \
  --image-ids "imageTag=agentcore-${REVISION}" --query 'imageDetails[0].imageDigest' --output text)"
[[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "ERROR: ECR returned no image digest for $TAG" >&2; exit 1; }
echo "${IMAGE_NAME}@${DIGEST}"
