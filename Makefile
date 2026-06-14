# os-fhir-server-bench — command reference. Run `make help`.
# Lifecycle:  check → smoke → (review) → benchmark → status/report → teardown
SHELL := /bin/bash
INFRA := infra

.PHONY: help check provision teardown clean clean-blob smoke benchmark status stop report seed run

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

# ─── primary: run on Azure, laptop-free; report → Blob URL; auto-stops VMs if enabled ───

smoke: provision ## Quick validation run (small data, 1 rep, short windows, truncated ladder) — detached
	@echo "==> smoke: small / 1 rep / 15s+30s windows / closed-model concurrency [1 8 32] — detached on the VMs"
	@SIZE=small REPS=1 WARMUP_S=15 MEASURE_S=30 \
	   CONCURRENCY_LEVELS="1 8 32" \
	   orchestrator/run-detached.sh

benchmark: provision ## The full run (bench.config.yaml: size, reps, windows, full ramp) — detached
	@orchestrator/run-detached.sh

status: ## Show the in-flight run's progress (log tail / DONE)
	@set -a; . ./.detached.env 2>/dev/null; set +a; \
	  ssh $$SSH_OPTS $$ADMIN@$$LOADGEN_IP "if [ -f $$REPO/run.done ]; then echo \"== DONE (exit \$$(cat $$REPO/run.exit))\"; fi; tail -n 20 $$REPO/run.log" 2>/dev/null \
	  || echo "no detached run found (.detached.env missing — run 'make smoke' or 'make benchmark')"

stop: ## Stop the in-flight detached run (controller + workers, verified); DEALLOCATE=1 also halts VM billing
	@set -a; . ./.detached.env 2>/dev/null; set +a; \
	  if [ -z "$${LOADGEN_IP:-}" ]; then echo "no detached run found (.detached.env missing)"; \
	  else \
	    echo "==> stopping run on loadgen $$LOADGEN_IP (kill controller + workers, verify)"; \
	    ssh $$SSH_OPTS $$ADMIN@$$LOADGEN_IP 'bash -s' < orchestrator/kill-run.sh \
	      || echo "WARN: loadgen unreachable or processes lingered — if SSH timed out, your IP may have changed; 'make provision' re-locks SSH, then retry"; \
	    if [ -n "$${SUT_IP:-}" ]; then \
	      echo "==> clearing any in-flight restore on sut $$SUT_IP"; \
	      ssh $$SSH_OPTS $$ADMIN@$$SUT_IP 'pkill -KILL -f pg_restore 2>/dev/null; pkill -KILL -f restore_postgres 2>/dev/null; true' \
	        || echo "WARN: sut unreachable (NSG/IP?)"; \
	    fi; \
	  fi
	@if [ "$(DEALLOCATE)" = "1" ]; then \
	    echo "==> deallocating all VMs (compute billing stops; disks/IPs remain until 'make teardown')"; \
	    az vm deallocate --ids $$(az vm list -g $$(bin/cfg azure.resource_group) --query '[].id' -o tsv); \
	  else echo "VMs still running — billing continues. Re-run with DEALLOCATE=1 to halt it, or 'make teardown' to remove."; fi

report: ## Show the latest run's report + run log from Blob (works after auto-stop; pass a run-… prefix to pick one)
	@bin/fetch-report.sh $(RUN)

clean-blob: ## Delete ALL run results from the Blob container (start fresh)
	@ACCT=$$(cd $(INFRA) && terraform output -raw storage_account); \
	  az storage blob delete-batch --account-name "$$ACCT" \
	    --account-key "$$(az storage account keys list -g $$(bin/cfg azure.resource_group) -n $$ACCT --query '[0].value' -o tsv)" \
	    --source "$$(bin/cfg reporting.blob_container)" && echo "cleared Blob container"

# ─── setup & lifecycle ───

check: ## Preflight: tools, Azure auth, config — provisions nothing
	@bin/preflight.sh

provision: ## Create the Azure infra (idempotent); auto-locks SSH to your IP; restarts stopped VMs
	@bin/lock-ssh-ip.sh
	cd $(INFRA) && terraform init -input=false && terraform apply -auto-approve
	@bin/start-vms.sh   # terraform won't restart deallocated VMs — do it so reruns work after auto-stop

teardown: ## Destroy all Azure resources — stop billing (run when done)
	cd $(INFRA) && terraform destroy -auto-approve

clean: ## Remove local generated dataset/snapshots/results
	rm -rf dataset/output dataset/snapshots results

# ─── advanced: individual orchestrator stages (operate on already-provisioned infra) ───

seed: ## [stage] generate Synthea + load each server + snapshot
	@orchestrator/orchestrate.sh seed

run: ## [stage] run the matrix (servers x scenarios x reps) + write manifest
	@orchestrator/orchestrate.sh run
