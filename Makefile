# os-fhir-server-bench — stage runner.
# `./reproduce.sh` chains these in order; you can also run any stage alone.

SHELL := /bin/bash
INFRA := infra

.PHONY: help check infra-up infra-down seed run report clean validate-small

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

validate-small: ## Fast Azure smoke: small dataset, 1 rep, short windows, SSH locked to your IP, VMs kept up
	@MYIP=$$(curl -fsS ifconfig.me) || { echo "could not detect public IP"; exit 1; }; \
	  perl -i -pe "s#^(\s*allowed_ssh_cidr:).*#\1 \"$$MYIP/32\"#" bench.config.yaml; \
	  echo "==> validate-small: SSH locked to $$MYIP/32; size=small, 1 rep, 15s warm-up / 30s measure; KEEP_INFRA=1"; \
	  echo "    (size/reps/windows are env overrides for THIS run only — your committed config is untouched)"; \
	  SIZE=small REPS=1 WARMUP_S=15 MEASURE_S=30 KEEP_INFRA=1 ./reproduce.sh
