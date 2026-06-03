# servers/hapi/

**HAPI FHIR JPA Server** comparator — `hapiproject/hapi:v7.4.0`, Postgres-backed,
on the identical CPU/mem envelope from `bench.config.yaml`. **Boot-verified** locally:
metadata + CRUD + search all green, Postgres snapshot/restore works.

- Port `8080`, base path `/fhir`, readiness `GET /fhir/metadata`.
- Engine: Postgres 16 → reuses `dataset/snapshot_postgres.sh` / `restore_postgres.sh`
  (DB `hapi`/`hapi`/`hapi`, declared in `manifest.yaml`).

## Gotcha worth knowing

The image's baked `application.yaml` sets the Hibernate dialect as a **map key**
(`spring.jpa.properties.hibernate.dialect`, defaulting to an H2 dialect). A plain
environment variable **cannot** override a map key, so the dialect was silently
ignored and Hibernate emitted generic `clob` DDL that Postgres rejects — leaving the
schema half-created and every write failing with 500. Fix: override via
`SPRING_APPLICATION_JSON` (high precedence, binds nested keys) with
`ca.uhn.fhir.jpa.model.dialect.HapiFhirPostgresDialect`. See `compose.yaml`.

## Usage

```bash
./build.sh   # docker compose pull
./up.sh      # start db+server, wait for /fhir/metadata
./down.sh    # stop (-v to wipe volumes)
```

Ports/limits come from `bench.config.yaml` (exported by the scripts via `_lib/lib.sh`);
`compose.yaml` reads them from the environment.
