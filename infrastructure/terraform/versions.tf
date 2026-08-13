terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # Used only to apply the ArgoCD root Application (app-of-apps) after the
    # cluster exists. Everything else in-cluster is owned by ArgoCD, not Terraform.
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    # Drives `aws eks create-capability` for the EKS Managed capabilities
    # (ArgoCD / ACK / KRO) — see capabilities.tf for why this is a CLI call.
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}
