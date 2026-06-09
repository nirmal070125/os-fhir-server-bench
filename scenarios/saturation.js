// saturation — find max sustainable throughput. Steps the offered read load up
// (ramping arrival rate) until the SLO trips; abortOnFail stops the run at the
// breakpoint, so the last sustained step ≈ max sustainable throughput. Uses the
// same read mix as read-mix.js (reads are the standard saturation probe and keep
// DB state unchanged across the ramp).
import http from 'k6/http';
import {
  BASE, JSON_HEADERS, constantArrival, rampingArrival, thresholds, record,
  collectIds, randItem, summary, SUMMARY_TREND_STATS,
} from './lib/common.js';

// WARMUP=1 (set by run.sh for the discarded warm-up pass) runs a short CONSTANT
// load at the start rate instead of the full ramp — enough to warm JIT/cache/pools,
// without the cost of running the entire ramp twice. The measured pass (no WARMUP)
// is the real ramp with SLO abort, unchanged.
const WARMUP = !!__ENV.WARMUP;
export const options = {
  scenarios: WARMUP ? constantArrival('saturation_warmup') : rampingArrival('saturation'),
  thresholds: WARMUP ? {} : thresholds(true), // no abort during warm-up
  summaryTrendStats: SUMMARY_TREND_STATS,
};

export function setup() {
  const patients = collectIds('Patient', Number(__ENV.POOL_SIZE || 1000));
  if (patients.length === 0) {
    throw new Error('saturation: no Patients found — seed the dataset before running');
  }
  return { patients };
}

const WEIGHTS = { read: 45, searchPage: 20, obsForPatient: 20, condForPatient: 10, history: 5 };

function pickOp() {
  let r = Math.random() * 100;
  for (const [op, w] of Object.entries(WEIGHTS)) {
    if ((r -= w) <= 0) return op;
  }
  return 'read';
}

export default function (data) {
  const id = randItem(data.patients);
  switch (pickOp()) {
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

export const handleSummary = summary('saturation');
