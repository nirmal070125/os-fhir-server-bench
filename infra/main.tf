# All tunables come from the repo-root bench.config.yaml — read once here.
locals {
  cfg         = yamldecode(file("${path.module}/../bench.config.yaml"))
  name_prefix = "fhirbench"

  # Parallel mode: provision ONE isolated SUT+loadgen "lane" per ENABLED server, each
  # pinned to an availability zone round-robin over [1,2,3] (so co-located lanes are
  # spread across zones — Azure guarantees ≥3 zones in any zone-enabled region). When
  # off, a single base stack is left zoneless (regional), exactly as before.
  #
  # The lane COUNT is DERIVED from servers.*.enabled — never restated. parallel_stacks
  # is a plain on/off boolean; "how many lanes" is just "how many enabled servers".
  parallel        = try(local.cfg.azure.parallel_stacks, false)
  enabled_servers = sort([for k, v in local.cfg.servers : k if try(v.enabled, false)])
  stack_count     = local.parallel ? max(length(local.enabled_servers), 1) : 1

  # SUT and LOADGEN are NEVER Spot: the SUT because eviction mid-measurement would
  # corrupt a result, the loadgen because it runs the whole controller (generate/seed/k6
  # + the ssh leg to the SUT) — a Spot eviction there deallocates the VM and silently
  # kills the entire run mid-flight. Only obs (Grafana/Prometheus, non-critical to the
  # result) follows the spot_enabled toggle.
  #
  # Lanes are numbered 1..stack_count -> sut1/loadgen1, sut2/loadgen2, … (uniform names;
  # no asymmetric base-vs-stack2 special case). zone = ((i-1) % 3) + 1 in parallel mode,
  # null (regional) for the single-stack case. 1024 GB SUT disk = Premium P30 (5,000 IOPS
  # / 200 MB/s): the SUT DB is IOPS-bound (random index writes), so disk SIZE buys the
  # IOPS that keep the server — not the disk — the bottleneck (also holds dataset +
  # snapshots). obs is a single SHARED node across all lanes.
  lane_nodes = merge([for i in range(1, local.stack_count + 1) : {
    "sut${i}" = {
      size       = local.cfg.azure.vm_sizes.sut
      spot       = false
      cloud_init = "sut.yaml"
      disk_gb    = 1024
      zone       = local.parallel ? tostring((i - 1) % 3 + 1) : null
    }
    "loadgen${i}" = {
      size       = local.cfg.azure.vm_sizes.loadgen
      spot       = false # controller host — must not be evictable
      cloud_init = "loadgen.yaml"
      disk_gb    = 64
      zone       = local.parallel ? tostring((i - 1) % 3 + 1) : null
    }
  }]...)

  obs_node = {
    obs = {
      size       = local.cfg.azure.vm_sizes.obs
      spot       = local.cfg.azure.spot_enabled
      cloud_init = "obs.yaml"
      disk_gb    = 64
      zone       = local.parallel ? "1" : null
    }
  }

  nodes = merge(local.lane_nodes, local.obs_node)

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
