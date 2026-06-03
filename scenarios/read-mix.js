// read-mix — steady, read-dominated real-world traffic at a constant arrival rate.
// A realistic clinical read mix against EXISTING seeded data: instance reads,
// patient searches, and patient-scoped clinical queries. No writes (state stays
// identical across reps so the comparison is fair).
import http from 'k6/http';
import {
  BASE, JSON_HEADERS, constantArrival, thresholds, record,
  collectIds, randItem, summary, SUMMARY_TREND_STATS,
} from './lib/common.js';

export const options = {
  scenarios: constantArrival('read_mix'),
  thresholds: thresholds(false),
  summaryTrendStats: SUMMARY_TREND_STATS,
};

// Build a pool of real ids once, shared with every VU.
export function setup() {
  const patients = collectIds('Patient', Number(__ENV.POOL_SIZE || 1000));
  if (patients.length === 0) {
    throw new Error('read-mix: no Patients found — seed the dataset before running');
  }
  return { patients };
}

// Weighted clinical read mix (must sum to 100). Tunable via READ_MIX_WEIGHTS
// JSON env, else these realistic defaults.
const WEIGHTS = __ENV.READ_MIX_WEIGHTS
  ? JSON.parse(__ENV.READ_MIX_WEIGHTS)
  : { read: 45, searchPage: 20, obsForPatient: 20, condForPatient: 10, history: 5 };

function pickOp() {
  let r = Math.random() * 100;
  for (const [op, w] of Object.entries(WEIGHTS)) {
    if ((r -= w) <= 0) return op;
  }
  return 'read';
}

export default function (data) {
  const id = randItem(data.patients);
  const op = pickOp();
  switch (op) {
    case 'read':
      record(http.get(`${BASE}/Patient/${id}`, { headers: JSON_HEADERS }), 'patient-read');
      break;
    case 'searchPage':
      record(http.get(`${BASE}/Patient?_count=20`, { headers: JSON_HEADERS }), 'patient-search');
      break;
    case 'obsForPatient':
      record(http.get(`${BASE}/Observation?patient=Patient/${id}&_count=50`, { headers: JSON_HEADERS }), 'observation-search');
      break;
    case 'condForPatient':
      record(http.get(`${BASE}/Condition?patient=Patient/${id}&_count=50`, { headers: JSON_HEADERS }), 'condition-search');
      break;
    case 'history':
      record(http.get(`${BASE}/Patient/${id}/_history?_count=10`, { headers: JSON_HEADERS }), 'patient-history');
      break;
  }
}

export const handleSummary = summary('read-mix');
