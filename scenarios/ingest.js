// ingest — sustained writes at a fixed OFFERED RATE (open model,
// constant-arrival-rate). Each iteration POSTs a FHIR transaction bundle (Patient +
// Encounter + 2 Observations) to the system endpoint — exactly the path the seeder
// uses, exercising the transaction-bundle endpoint (PR #165). New random resources
// each time. The snapshot is restored before each rate level, so every level
// measures write throughput on top of the same seeded baseline. One level per run.
import http from 'k6/http';
import exec from 'k6/execution';
import {
  BASE, JSON_HEADERS, constantArrival, thresholds, record, summary, SUMMARY_TREND_STATS,
} from './lib/common.js';

export const options = {
  scenarios: constantArrival('ingest'),
  thresholds: thresholds(),
  summaryTrendStats: SUMMARY_TREND_STATS,
};

// Dependency-free unique id (no remote uuid jslib). Uniqueness across VUs/iters
// is all we need for intra-bundle urn:uuid references.
function uid() {
  const a = exec.vu.idInTest;
  const b = exec.scenario.iterationInTest;
  const c = Math.floor(Math.random() * 1e9).toString(16);
  return `${a}-${b}-${c}`;
}

function makeBundle() {
  const p = `urn:uuid:patient-${uid()}`;
  const e = `urn:uuid:encounter-${uid()}`;
  const entry = (fullUrl, resource, urlType) => ({
    fullUrl,
    resource,
    request: { method: 'POST', url: urlType },
  });
  return JSON.stringify({
    resourceType: 'Bundle',
    type: 'transaction',
    entry: [
      entry(p, {
        resourceType: 'Patient',
        name: [{ family: 'BenchIngest', given: ['Load'] }],
        gender: Math.random() < 0.5 ? 'male' : 'female',
        birthDate: '1980-01-01',
      }, 'Patient'),
      entry(e, {
        resourceType: 'Encounter',
        status: 'finished',
        class: { system: 'http://terminology.hl7.org/CodeSystem/v3-ActCode', code: 'AMB' },
        subject: { reference: p },
      }, 'Encounter'),
      entry(`urn:uuid:obs-${uid()}`, {
        resourceType: 'Observation',
        status: 'final',
        code: { coding: [{ system: 'http://loinc.org', code: '8867-4', display: 'Heart rate' }] },
        subject: { reference: p },
        encounter: { reference: e },
        valueQuantity: { value: 60 + Math.floor(Math.random() * 40), unit: 'beats/minute' },
      }, 'Observation'),
      entry(`urn:uuid:obs-${uid()}`, {
        resourceType: 'Observation',
        status: 'final',
        code: { coding: [{ system: 'http://loinc.org', code: '8480-6', display: 'Systolic blood pressure' }] },
        subject: { reference: p },
        encounter: { reference: e },
        valueQuantity: { value: 100 + Math.floor(Math.random() * 40), unit: 'mmHg' },
      }, 'Observation'),
    ],
  });
}

export default function () {
  // FHIR transaction is POSTed to the base (system) endpoint; success = 200.
  record(http.post(BASE, makeBundle(), { headers: JSON_HEADERS }), 'transaction-bundle', 200);
}

export const handleSummary = summary('ingest');
