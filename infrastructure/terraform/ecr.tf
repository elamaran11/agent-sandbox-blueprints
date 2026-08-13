# ── ECR repositories for the agent (coder) images ─────────────────────────────
#
# Two images, because the substrates need different builds:
#
#   dark-factory-coder          x86_64 — the Kata agent (runs as a pod)
#   dark-factory-coder-microvm  arm64  — the Lambda MicroVM agent. AWS Lambda
#                                        MicroVM is ARM64-only, and this image
#                                        wraps the same agent in the hook-server
#                                        the MicroVM snapshot runtime expects.
#
# The MicroVM image is not launched from ECR directly: Lambda builds it from an
# S3 code artifact whose Dockerfile pulls this image as its base layer, which is
# why the MicroVM build role keeps ecr:Get*/BatchGetImage.

locals {
  coder_repos = var.create_coder_ecr_repos ? {
    coder         = "dark-factory-coder"
    coder_microvm = "dark-factory-coder-microvm"
  } : {}
}

resource "aws_ecr_repository" "coder" {
  for_each = local.coder_repos

  name                 = each.value
  image_tag_mutability = "MUTABLE"
  # Blueprint convenience: lets `terraform destroy` clean up without manual
  # image deletion. Do not carry this setting into a real registry.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = local.tags
}

resource "aws_ecr_lifecycle_policy" "coder" {
  for_each = aws_ecr_repository.coder

  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the 10 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}
