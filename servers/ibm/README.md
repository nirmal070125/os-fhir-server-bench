# servers/ibm/  ⚠️ scaffolded, not yet boot-verified

**IBM / LinuxForHealth FHIR Server** (`ghcr.io/linuxforhealth/fhir-server`), on
Open Liberty. **HTTPS** on 9443, base path `/fhir-server/api/v4`, readiness
`GET /fhir-server/api/v4/$healthcheck`, **basic auth** `fhiruser` / `change-password`.

**Two caveats before it's a fair comparator:**

1. **HTTPS + auth.** Clients need `-k` (self-signed TLS) and an `Authorization: Basic`
   header. `seed.sh` and the k6 scenarios need the same optional-auth hook described in
   `servers/medplum/README.md` (env-driven header + insecure-TLS flag, empty/off for the
   open servers) so the one set of scripts serves every server.
2. **Datastore.** The image boots with embedded **Derby** (`BOOTSTRAP_DB=true`) — quick
   to stand up but not representative. For the real run, point it at Postgres: run the
   `fhir-persistence-schema` tool to create the schema, then mount a `datasource.xml`
   drop-in. The compose ships a `db` service behind the `postgres` profile so this is a
   documented switch, not a rewrite. The manifest already declares `engine: postgres`.

**To finalize:** start with Derby (`./up.sh`) to confirm the health/auth path, add the
auth hook, then complete the Postgres bootstrap and flip the datasource. Lifecycle/limits
follow the verified-profile pattern.
