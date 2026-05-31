# servers/

One directory per server under test: docker-compose + pinned image digest + tuned
config + the identical CPU/mem limits from `bench.config.yaml`.

- `fhir-server-go/` — built from `feat/fhir-server-go-transaction-bundle` (plan step 4)
- hapi/ microsoft/ ibm/ medplum/ blaze/ — added in plan steps 9–11.
