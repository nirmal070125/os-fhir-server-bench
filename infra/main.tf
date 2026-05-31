# All tunables come from the repo-root bench.config.yaml — read once here.
locals {
  cfg         = yamldecode(file("${path.module}/../bench.config.yaml"))
  name_prefix = "fhirbench"

  # The three roles. SUT is NEVER Spot (eviction mid-measurement would corrupt a
  # result); load-gen + observability follow the spot_enabled toggle.
  nodes = {
    sut = {
      size       = local.cfg.azure.vm_sizes.sut
      spot       = false
      cloud_init = "sut.yaml"
      disk_gb    = 256 # dataset + per-engine snapshots live here
    }
    loadgen = {
      size       = local.cfg.azure.vm_sizes.loadgen
      spot       = local.cfg.azure.spot_enabled
      cloud_init = "loadgen.yaml"
      disk_gb    = 64
    }
    obs = {
      size       = local.cfg.azure.vm_sizes.obs
      spot       = local.cfg.azure.spot_enabled
      cloud_init = "obs.yaml"
      disk_gb    = 64
    }
  }

  tags = {
    project = "os-fhir-server-bench"
    managed = "terraform"
  }
}

resource "azurerm_resource_group" "rg" {
  name     = local.cfg.azure.resource_group
  location = local.cfg.azure.location
  tags     = local.tags
}
