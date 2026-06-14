# All tunables come from the repo-root bench.config.yaml — read once here.
locals {
  cfg         = yamldecode(file("${path.module}/../bench.config.yaml"))
  name_prefix = "fhirbench"

  # Parallel mode: provision a 2nd SUT+loadgen stack pinned to a different availability
  # zone (so the two SUTs can't share a host). When off, the base stack is left zoneless
  # (regional), exactly as before — no placement change for the single-stack case.
  parallel = try(local.cfg.azure.parallel_stacks, false)

  # The base roles. SUT and LOADGEN are NEVER Spot: the SUT because eviction
  # mid-measurement would corrupt a result, the loadgen because it runs the whole
  # controller (generate/seed/k6 + the ssh leg to the SUT) — a Spot eviction there
  # deallocates the VM and silently kills the entire run mid-flight (which is exactly
  # what happened: the loadgen was evicted during seeding and the run froze). Only obs
  # (Grafana/Prometheus, non-critical to the result) follows the spot_enabled toggle.
  # `zone` is null (regional) unless parallel mode pins the base stack to zone 1.
  base_nodes = {
    sut = {
      size       = local.cfg.azure.vm_sizes.sut
      spot       = false
      cloud_init = "sut.yaml"
      # 1024 GB = Premium P30 = 5,000 IOPS / 200 MB/s. Premium IOPS scale with disk
      # SIZE, and the SUT's DB is IOPS-bound (random index writes), not space-bound —
      # P15 (256 GB / 1,100 IOPS) bottlenecked both the seed AND the measured write
      # numbers, so the result reflected the disk, not the server. P30 makes the server
      # the limit. (Holds the dataset + per-engine snapshots too, with room to spare.)
      disk_gb = 1024
      zone    = local.parallel ? "1" : null
    }
    loadgen = {
      size       = local.cfg.azure.vm_sizes.loadgen
      spot       = false # controller host — must not be evictable
      cloud_init = "loadgen.yaml"
      disk_gb    = 64
      zone       = local.parallel ? "1" : null
    }
    obs = {
      size       = local.cfg.azure.vm_sizes.obs
      spot       = local.cfg.azure.spot_enabled
      cloud_init = "obs.yaml"
      disk_gb    = 64
      zone       = local.parallel ? "1" : null
    }
  }

  # Second isolated stack (one server per stack), pinned to availability zone 2 so its
  # SUT never shares a physical host with the zone-1 SUT. Created only in parallel mode.
  stack2_nodes = {
    sut2 = {
      size       = local.cfg.azure.vm_sizes.sut
      spot       = false
      cloud_init = "sut.yaml"
      disk_gb    = 1024
      zone       = "2"
    }
    loadgen2 = {
      size       = local.cfg.azure.vm_sizes.loadgen
      spot       = false
      cloud_init = "loadgen.yaml"
      disk_gb    = 64
      zone       = "2"
    }
  }

  nodes = local.parallel ? merge(local.base_nodes, local.stack2_nodes) : local.base_nodes

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
