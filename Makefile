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
	@echo "[seed] implemented in plan step 6 (orchestrator). Dataset scripts live in dataset/."

run: ## Execute the benchmark matrix (servers x scenarios x reps)
	@echo "[run] implemented in plan steps 5-6 (k6 scenarios + orchestrator)."

report: ## Generate comparison report + upload artifacts to Blob
	@echo "[report] implemented in plan step 7 (reporting)."

clean: ## Remove local generated dataset/snapshots/results
	rm -rf dataset/output dataset/snapshots results
