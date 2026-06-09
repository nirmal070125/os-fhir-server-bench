#!/usr/bin/env bash
# Generate a DETERMINISTIC Synthea FHIR dataset from bench.config.yaml.
# Same config + seed + reference date → byte-identical transaction bundles.
# Runs on the load-gen VM (needs a JDK; installed by cloud-init).
#   dataset/generate.sh [output_dir]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cfg() { "$ROOT/bin/cfg" "$1"; }

VERSION="$(cfg dataset.synthea_version)"
SEED="$(cfg dataset.seed)"
REFDATE="$(cfg dataset.reference_date)"
SIZE="${SIZE:-$(cfg dataset.size)}"
POP="$(cfg "dataset.populations.${SIZE}")"

OUT="${1:-$ROOT/dataset/output/$SIZE}"
JAR="$ROOT/dataset/synthea-with-dependencies-${VERSION}.jar"
JAR_URL="https://github.com/synthetichealth/synthea/releases/download/v${VERSION}/synthea-with-dependencies.jar"

mkdir -p "$OUT"
if [[ ! -f "$JAR" ]]; then
  echo "==> Downloading Synthea v$VERSION"
  curl -fsSL "$JAR_URL" -o "$JAR"
fi

# Synthea writes per-patient files named after the patient; non-ASCII names (e.g.
# "Débora") need a UTF-8 locale or the JVM throws InvalidPathException and DROPS
# that patient — yielding a short, non-deterministic dataset. Minimal cloud images
# default to an ASCII locale, so force UTF-8 on Linux (macOS is already UTF-8; we
# leave its working locale untouched to avoid the invalid-C.UTF-8 case).
if [[ "$(uname)" == "Linux" ]]; then export LANG=C.UTF-8 LC_ALL=C.UTF-8; fi

echo "==> Generating $POP patients (seed=$SEED, refdate=$REFDATE, locale=${LC_ALL:-default}) → $OUT"
java -Dfile.encoding=UTF-8 -jar "$JAR" \
  -p "$POP" \
  -s "$SEED" \
  -cs "$SEED" \
  -r "$REFDATE" \
  --exporter.baseDirectory "$OUT" \
  --exporter.fhir.export true \
  --exporter.fhir.transaction_bundle true \
  --exporter.hospital.fhir.export true \
  --exporter.practitioner.fhir.export true

echo "==> Done. Transaction bundles in $OUT/fhir"
echo "==> Dataset hash: $("$ROOT/dataset/hash.sh" "$OUT/fhir")"
