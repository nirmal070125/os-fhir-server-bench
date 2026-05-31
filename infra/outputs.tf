output "ssh_commands" {
  description = "Ready-to-paste SSH commands per node"
  value       = { for k, v in azurerm_public_ip.pip : k => "ssh ${local.cfg.azure.admin_username}@${v.ip_address}" }
}

output "public_ips" {
  value = { for k, v in azurerm_public_ip.pip : k => v.ip_address }
}

# The orchestrator uses these for in-VNet wiring (k6 → SUT, exporters → Prometheus).
output "private_ips" {
  value = { for k, v in azurerm_network_interface.nic : k => v.private_ip_address }
}

output "storage_account" {
  value = azurerm_storage_account.results.name
}

output "blob_container" {
  value = azurerm_storage_container.results.name
}

output "grafana_url" {
  description = "Grafana on the observability node (port 3000)"
  value       = "http://${azurerm_public_ip.pip["obs"].ip_address}:3000"
}
