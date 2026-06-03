# servers/medplum/  ⚠️ scaffolded, not yet boot-verified

**Medplum** (`medplum/medplum-server:3.2.7`), Postgres + Redis. FHIR at `/fhir/R4`,
port 8103, readiness `/healthcheck`. Engine is Postgres → reuses the Postgres
snapshot/restore.

**Key caveat — auth is mandatory.** Unlike fhir-server-go / HAPI / Blaze, Medplum has
no anonymous-write mode: every FHIR call needs an OAuth bearer token. So the shared
`dataset/seed.sh` (unauthenticated POST) and the k6 scenarios (no `Authorization`
header) will **not** work against Medplum unmodified.

**To finalize (the fair way to include Medplum):**
1. `./build.sh && ./up.sh`; on first boot Medplum auto-creates a super-admin + default
   project. Create a ClientApplication and obtain client-credentials.
2. Add an optional `Authorization: Bearer …` to `scenarios/lib/common.js` (env-driven,
   empty for the open servers) and to `seed.sh`, so the SAME scripts work for both
   auth and non-auth servers — preserving the "same API path" fairness rule.
3. Then enable in `bench.config.yaml` and run. Engine wiring (Postgres) is already done.

Lifecycle/ports/limits follow the verified-profile pattern.
