# AgentCore V2 snapshots this long-running HTTP host at its first healthy /ping.
# The base image carries entrypoint.js and the arm64 coder toolchain.
# No default: a baked ECR URI would point a fork at someone else's account.
# publish.sh supplies --build-arg CODER_IMAGE from the caller's environment.
ARG CODER_IMAGE
FROM ${CODER_IMAGE}

WORKDIR /app
COPY --chown=1000:1000 host.js /app/host.js
USER 1000
EXPOSE 8080
# Explicit CMD: the base coder image may have its own entrypoint/command.
CMD ["node", "/app/host.js"]
