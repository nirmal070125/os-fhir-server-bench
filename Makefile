# os-fhir-server-bench — command reference. Run `make help`.
# Lifecycle:  check → smoke → (review) → benchmark → status/report → teardown
SHELL := /bin/bash
INFRA := infra

.PHONY: help check provision teardown clean smoke benchmark status report seed run

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

# ─── primary: run on Azure, laptop-free; report → Blob URL; auto-stops VMs if enabled ───

smoke: provision ## Quick validation run (small data, 1 rep, short windows, truncated saturation) — detached
	@echo "==> smoke: small / 1 rep / 15s+30s windows / saturation ramp ->300 — detached on the VMs"
	@SIZE=small REPS=1 WARMUP_S=15 MEASURE_S=30 \
	   START_RATE=50 STEP_RATE=50 STEP_DURATION=5s MAX_RATE=300 \
	   orchestrator/run-detached.sh

benchmark: provision ## The full run (bench.config.yaml: size, reps, windows, full ramp) — detached
	@orchestrator/run-detached.sh

status: ## Show the in-flight run's progress (log tail / DONE)
	@set -a; . ./.detached.env 2>/dev/null; set +a; \
	  ssh $$SSH_OPTS $$ADMIN@$$LOADGEN_IP "if [ -f $$REPO/run.done ]; then echo \"== DONE (exit $$(cat $$REPO/run.exit))\"; fi; tail -n 20 $$REPO/run.log" 2>/dev/null \
	  || echo "no detached run found (.detached.env missing — run 'make smoke' or 'make benchmark')"

report: ## Pull latest results from the loadgen + build report.md locally (use the Blob URL after auto-stop)
	@set -a; . ./.detached.env 2>/dev/null; set +a; \
	  echo "==> fetching summaries + manifests (not the multi-GB raw metrics.json)"; \
	  ssh $$SSH_OPTS "$$ADMIN@$$LOADGEN_IP" "cd $$REPO && tar czf - \$$(find results \( -name summary.json -o -name run-manifest.json \) -print)" | tar xzf - && \
	  python3 reporting/report.py

# ─── setup & lifecycle ───

check: ## Preflight: tools, Azure auth, config — provisions nothing
	@bin/preflight.sh

provision: ## Create the Azure infra (idempotent); auto-locks SSH to your current IP
	@bin/lock-ssh-ip.sh
	cd $(INFRA) && terraform init -input=false && terraform apply -auto-approve

teardown: ## Destroy all Azure resources — stop billing (run when done)
	cd $(INFRA) && terraform destroy -auto-approve

clean: ## Remove local generated dataset/snapshots/results
	rm -rf dataset/output dataset/snapshots results

# ─── advanced: individual orchestrator stages (operate on already-provisioned infra) ───

seed: ## [stage] generate Synthea + load each server + snapshot
	@orchestrator/orchestrate.sh seed

run: ## [stage] run the matrix (servers x scenarios x reps) + write manifest
	@orchestrator/orchestrate.sh run
