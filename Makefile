# os-fhir-server-bench — stage runner.
# `./reproduce.sh` chains these in order; you can also run any stage alone.

SHELL := /bin/bash
INFRA := infra

.PHONY: help check infra-up infra-down seed run report clean validate-small \
        run-detached run-status fetch-results

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

check: ## Validate config + credentials before spending anything
	@bin/preflight.sh

infra-up: ## Provision Azure VMs + network + storage (Terraform); auto-locks SSH to your IP
	@bin/lock-ssh-ip.sh
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

run-detached: ## Launch the run ON the loadgen VM in tmux (survives laptop sleep). Infra must be up.
	@orchestrator/run-detached.sh

run-status: ## Show detached-run status (run.log tail / DONE)
	@set -a; . ./.detached.env; set +a; \
	  ssh $$SSH_OPTS $$ADMIN@$$LOADGEN_IP "if [ -f $$REPO/run.done ]; then echo \"== DONE (exit $$(cat $$REPO/run.exit))\"; fi; tail -n 20 $$REPO/run.log" 2>/dev/null \
	  || echo "no detached run found (.detached.env missing — run 'make run-detached')"

fetch-results: ## Pull ONLY summaries + manifests from the loadgen VM and build the report locally
	@set -a; . ./.detached.env; set +a; \
	  echo "==> fetching summaries + manifests (not the multi-GB raw metrics.json)"; \
	  ssh $$SSH_OPTS "$$ADMIN@$$LOADGEN_IP" "cd $$REPO && tar czf - \$$(find results \( -name summary.json -o -name run-manifest.json \) -print)" | tar xzf - && \
	  python3 reporting/report.py

validate-small: ## Fast Azure smoke: small dataset, 1 rep, short windows, VMs kept up (SSH IP auto-locked at infra-up)
	@echo "==> validate-small: size=small, 1 rep, 15s warm-up / 30s measure; KEEP_INFRA=1"
	@echo "    (size/reps/windows are env overrides for THIS run only; SSH IP auto-locks at infra-up)"
	@SIZE=small REPS=1 WARMUP_S=15 MEASURE_S=30 KEEP_INFRA=1 ./reproduce.sh
