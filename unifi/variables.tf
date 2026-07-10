variable "unifi_api_key" {
  description = "UniFi controller API key (preferred over username/password)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "unifi_username" {
  description = "UniFi controller username (not needed if using api_key)"
  type        = string
  default     = ""
}

variable "unifi_password" {
  description = "UniFi controller password (not needed if using api_key)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "unifi_api_url" {
  description = "UniFi controller API URL"
  type        = string
  default     = "https://10.1.0.1"
}

variable "site" {
  description = "UniFi site name"
  type        = string
  default     = "default"
}

variable "pihole_url" {
  description = "Pi-hole URL (include port if non-standard)"
  type        = string
  default     = "https://pi.hole"
}

variable "pihole_password" {
  description = "Pi-hole admin password"
  type        = string
  sensitive   = true
}
