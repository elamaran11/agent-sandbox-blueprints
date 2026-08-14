# Flow D — lambda-coder image: the dark-factory coder wrapped for the Lambda MicroVM
# snapshot/hook runtime.
#
# FROM the arm64 dark-factory-coder (Lambda MicroVM is ARM_64-only) — it carries
# entrypoint.js + the toolchain (git, node, claude-code). We add ONLY the hook server
# that adapts the one-shot coder to the MicroVM lifecycle (see hook-server.js): the
# /run hook background-spawns entrypoint.js with USE_BEDROCK=1 so the coder calls
# Bedrock directly via the MicroVM execution role — no Bifrost / EKS-network path.
#
# The image is built by Lambda from a code-artifact ZIP (this Dockerfile + hook-server.js)
# in S3 — NOT pushed to ECR as a normal image. The base coder image IS pulled from ECR
# during that build (the MicrovmImage build role keeps ecr:Get*).
# No default on purpose: a baked ECR URI would build FROM another account's image
# (or fail obscurely in a fork). publish.sh passes --build-arg CODER_IMAGE=...
# resolved from the terraform coder_ecr_urls output.
ARG CODER_IMAGE
FROM ${CODER_IMAGE}

WORKDIR /app

# The hook server (serves ready/validate/run/suspend/resume/terminate on :8080).
COPY hook-server.js /app/hook-server.js

# Ship the UPDATED coder over the one baked into the ECR base. The base image's
# entrypoint.js predates the USE_BEDROCK branch; overlaying it here means the
# MicrovmImage build (which pulls the ECR base) gets the Bedrock-capable coder
# WITHOUT a separate ECR rebuild+push. Keep in sync with examples/dark-factory/coder/entrypoint.js.
COPY entrypoint.js /app/entrypoint.js

# Lambda MicroVM snapshots the process started here. hooks.port on the MicrovmImage
# must match this (8080). The server stays up (long-running) so the VM isn't idle-
# suspended mid coder-run — the Microvm idlePolicy.maxIdleDurationSeconds is set
# longer than a coder run.
EXPOSE 8080
CMD ["node", "/app/hook-server.js"]
