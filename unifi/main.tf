terraform {
  required_version = ">= 1.0"

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

  # Local state for home lab
  backend "local" {
    path = "terraform.tfstate"
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
