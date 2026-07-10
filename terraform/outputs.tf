output "masters" {
  description = "Master node name -> IP"
  value       = { for k, v in var.masters : k => v.ip }
}

output "workers" {
  description = "Worker node name -> IP"
  value       = { for k, v in var.workers : k => v.ip }
}

output "ansible_inventory_ips" {
  description = "All node IPs, for generating the Ansible inventory"
  value = {
    masters = [for v in var.masters : v.ip]
    workers = [for v in var.workers : v.ip]
  }
}
