terraform {
  required_version = ">= 1.10"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
  }

  # State lives in S3 (moved from local 2026-09-27): bucket
  # banghart-terraform-state is versioned, SSE-encrypted, public access
  # blocked, and not managed by any Terraform here. use_lockfile gives native
  # S3 state locking, so plan/apply is safe from devbox or the desktop.
  # Credentials come from the default AWS chain (~/.aws [default]).
  backend "s3" {
    bucket       = "banghart-terraform-state"
    key          = "homelab/k8s-homelab/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_api_url
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_tls_insecure

  ssh {
    agent    = true
    username = "root"
  }
}
