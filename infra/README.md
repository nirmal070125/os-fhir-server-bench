# infra/

Terraform (`azurerm` provider) that stands up the benchmark environment. Driven by
`make provision` / `make teardown` — you normally never run `terraform` by hand.

It reads `../bench.config.yaml` directly via `yamldecode()`, so the config file is the single
source of truth for region, VM sizes, and the parallel-stack toggle. Azure auth comes from the
`ARM_*` environment variables in `.env` (see `../.env.example`) — **no secrets live here**.

| File | What it creates |
|---|---|
| `versions.tf` | Provider + required-version pins (`.terraform.lock.hcl` is committed for reproducibility). |
| `main.tf` | Resource group, the VM node map, and shared wiring (managed identity / role assignment when `auto_stop_when_done`). |
| `vms.tf` | The VMs: a shared `obs` plus one `sut<i>`/`loadgen<i>` lane. Single-stack mode has `sut1`/`loadgen1` (regional); with `azure.parallel_stacks: true` it provisions one lane per enabled server (`sut1..N`/`loadgen1..N`), zone round-robin over [1,2,3]. |
| `network.tf` | VNet/subnet (`10.10.0.0/16`), NSG. SSH is locked to `azure.allowed_ssh_cidr` (set by `bin/lock-ssh-ip.sh` at provision). |
| `storage.tf` | Storage account + Blob container for result artifacts. |
| `outputs.tf` | IPs / names consumed by the orchestrator (`make status`, detached runs). |
| `cloud-init/` | First-boot setup that installs Docker/k6/tooling on the VMs — nothing is installed on your laptop. |

State (`*.tfstate`) and the local `.terraform/` cache are gitignored and machine-local; the
lock file is not. **Reminder:** these resources cost money while they exist — run
`make teardown` (or enable `auto_stop_when_done`) when finished. See the Disclaimer in the
top-level `README.md`.
