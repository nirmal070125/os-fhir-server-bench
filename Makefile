# os-fhir-server-bench — stage runner.
# `./reproduce.sh` chains these in order; you can also run any stage alone.

SHELL := /bin/bash
INFRA := infra

.PHONY: help check infra-up infra-down seed run report clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

check: ## Validate config + credentials before spending anything
	@bin/preflight.sh

infra-up: ## Provision Azure VMs + network + storage (Terraform)
	cd $(INFRA) && terraform init -input=false && terraform apply -auto-approve

infra-down: ## Destroy all Azure resources (run this when done!)
	cd $(INFRA) && terraform destroy -auto-approve

seed: ## Generate Synthea dataset, load into each enabled server, snapshot
	@orchestrator/orchestrate.sh seed

run: ## Execute the benchmark matrix (servers x scenarios x reps)
	@orchestrator/orchestrate.sh run

report: ## Generate comparison report + upload artifacts to Blob
	@python3 reporting/report.py
	@if [[ -n "$${BENCH_STORAGE_ACCOUNT:-}" ]]; then reporting/upload.sh; else echo "[report] BENCH_STORAGE_ACCOUNT unset — skipping Blob upload (report.md/csv are in results/)"; fi

clean: ## Remove local generated dataset/snapshots/results
	rm -rf dataset/output dataset/snapshots results
