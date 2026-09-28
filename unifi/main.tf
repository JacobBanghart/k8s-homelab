terraform {
  required_version = ">= 1.10"

  required_providers {
    unifi = {
      source  = "ubiquiti-community/unifi"
      version = "0.53.0"
    }
    pihole = {
      source  = "ryanwholey/pihole"
      version = "2.0.0-beta.1"
    }
  }

  # State lives in S3 (moved from local 2026-09-27): bucket
  # banghart-terraform-state is versioned, SSE-encrypted, public access
  # blocked, and not managed by any Terraform here. use_lockfile gives native
  # S3 state locking, so plan/apply is safe from devbox or the desktop.
  # Credentials come from the default AWS chain (~/.aws [default]).
  backend "s3" {
    bucket       = "banghart-terraform-state"
    key          = "homelab/k8s-homelab/unifi.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "unifi" {
  api_key  = var.unifi_api_key
  username = var.unifi_username
  password = var.unifi_password
  api_url  = var.unifi_api_url

  allow_insecure = true
}

provider "pihole" {
  url      = var.pihole_url
  password = var.pihole_password
  ca_file  = "${path.module}/pihole-ca.pem"
}
