resource "azurerm_public_ip" "pip" {
  for_each            = local.nodes
  name                = "${local.name_prefix}-${each.key}-pip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_network_interface" "nic" {
  for_each            = local.nodes
  name                = "${local.name_prefix}-${each.key}-nic"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.pip[each.key].id
  }
}

resource "azurerm_linux_virtual_machine" "vm" {
  for_each              = local.nodes
  name                  = "${local.name_prefix}-${each.key}"
  location              = azurerm_resource_group.rg.location
  resource_group_name   = azurerm_resource_group.rg.name
  size                  = each.value.size
  zone                  = each.value.zone # null = regional (single-stack); "1"/"2" pins the parallel stacks apart
  admin_username        = local.cfg.azure.admin_username
  network_interface_ids = [azurerm_network_interface.nic[each.key].id]
  tags                  = local.tags

  # Spot pricing for loadgen + obs when enabled; SUT stays Regular.
  priority        = each.value.spot ? "Spot" : "Regular"
  eviction_policy = each.value.spot ? "Deallocate" : null
  max_bid_price   = each.value.spot ? -1 : null # -1 = pay up to on-demand, never evict on price

  # System-assigned managed identity (free, no secrets). Used by the loadgen for
  # auto-stop-when-done; harmless on the others.
  identity {
    type = "SystemAssigned"
  }

  admin_ssh_key {
    username   = local.cfg.azure.admin_username
    public_key = file(pathexpand(local.cfg.azure.ssh_public_key_path))
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = each.value.disk_gb
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  # Role-specific bootstrap (Docker, k6, Synthea/JDK, Prometheus+Grafana, yq).
  custom_data = base64encode(templatefile(
    "${path.module}/cloud-init/${each.value.cloud_init}",
    { admin_user = local.cfg.azure.admin_username }
  ))
}

# Auto-stop-when-done: let the loadgen's managed identity deallocate VMs in this RG
# (the detached run calls self-stop.sh after uploading the report). Gated by the
# config flag because creating a role assignment requires Owner/User-Access-Admin.
resource "azurerm_role_assignment" "loadgen_self_stop" {
  count                = try(local.cfg.azure.auto_stop_when_done, false) ? 1 : 0
  scope                = azurerm_resource_group.rg.id
  role_definition_name = "Virtual Machine Contributor"
  principal_id         = azurerm_linux_virtual_machine.vm["loadgen"].identity[0].principal_id
}

# Auto-shutdown backstop so forgotten VMs don't quietly bill at ~$1/hr.
resource "azurerm_dev_test_global_vm_shutdown_schedule" "shutdown" {
  for_each           = local.cfg.azure.auto_shutdown.enabled ? local.nodes : {}
  virtual_machine_id = azurerm_linux_virtual_machine.vm[each.key].id
  location           = azurerm_resource_group.rg.location
  enabled            = true

  daily_recurrence_time = local.cfg.azure.auto_shutdown.time
  timezone              = local.cfg.azure.auto_shutdown.timezone

  notification_settings {
    enabled = false
  }
}
