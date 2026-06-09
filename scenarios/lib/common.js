// Shared helpers for every scenario. No remote imports (loadgen VMs may be
// network-restricted) — everything here is self-contained k6 stdlib.
import http from 'k6/http';
import { check } from 'k6';
import { Rate, Trend } from 'k6/metrics';

// ---- environment / config -------------------------------------------------
// BASE_URL is required and must point at the FHIR base (…/fhir/r4).
export const BASE = (() => {
  const u = __ENV.BASE_URL;
  if (!u) throw new Error('BASE_URL is required (e.g. http://sut:9090/fhir/r4)');
  return u.replace(/\/$/, '');
})();

export const P99_MS = Number(__ENV.P99_MS || 500);
export const MAX_ERROR_RATE = Number(__ENV.MAX_ERROR_RATE || 0.001);

const num = (v, d) => (v === undefined || v === '' ? d : Number(v));

export const JSON_HEADERS = {
  'Content-Type': 'application/fhir+json',
  Accept: 'application/fhir+json',
};

// Optional auth for servers that require it (Medplum, IBM). Same scripts, same
// path — open servers just leave AUTH_HEADER unset. Format: "Header-Name: value",
// e.g. AUTH_HEADER='Authorization: Bearer X' or 'Authorization: Basic Y'.
// (Self-signed TLS: use k6's native K6_INSECURE_SKIP_TLS_VERIFY=true.)
if (__ENV.AUTH_HEADER) {
  const i = __ENV.AUTH_HEADER.indexOf(':');
  if (i < 1) throw new Error("AUTH_HEADER must look like 'Authorization: Bearer …'");
  JSON_HEADERS[__ENV.AUTH_HEADER.slice(0, i).trim()] = __ENV.AUTH_HEADER.slice(i + 1).trim();
}

// ---- custom metrics -------------------------------------------------------
// Tag every request with op=<name> so reporting can break latency down by
// operation; also a single business-level error rate across the scenario.
export const errors = new Rate('fhir_errors');
export const opDuration = new Trend('fhir_op_duration', true);

// Record a response: count 2xx as success, everything else as error, and add
// its latency to the per-op trend. Returns the parsed JSON body or null.
export function record(res, op, expectStatus) {
  const ok = expectStatus
    ? res.status === expectStatus
    : res.status >= 200 && res.status < 300;
  check(res, { [`${op} ok`]: () => ok });
  errors.add(!ok, { op });
  opDuration.add(res.timings.duration, { op });
  if (!ok) return null;
  try {
    return res.json();
  } catch (_e) {
    return null;
  }
}

// ---- executors ------------------------------------------------------------
// Constant arrival rate (open model): k6 issues `rate` iterations/sec
// regardless of how long each takes — the correct shape for steady-state.
export function constantArrival(name) {
  return {
    [name]: {
      executor: 'constant-arrival-rate',
      rate: num(__ENV.RATE, 100),
      timeUnit: '1s',
      duration: __ENV.DURATION || '60s',
      preAllocatedVUs: num(__ENV.PREALLOCATED_VUS, 50),
      maxVUs: num(__ENV.MAX_VUS, 500),
      exec: 'default',
    },
  };
}

// Ramping arrival rate: step the offered load up until the SLO threshold trips.
// With abortOnFail on the thresholds, the run stops at the breakpoint — the last
// sustained step approximates max sustainable throughput.
export function rampingArrival(name) {
  const start = num(__ENV.START_RATE, 50);
  const step = num(__ENV.STEP_RATE, 50);
  const max = num(__ENV.MAX_RATE, 2000);
  const stepDur = __ENV.STEP_DURATION || '30s';
  const stages = [];
  for (let r = start; r <= max; r += step) {
    stages.push({ target: r, duration: stepDur });
  }
  return {
    [name]: {
      executor: 'ramping-arrival-rate',
      startRate: start,
      timeUnit: '1s',
      stages,
      preAllocatedVUs: num(__ENV.PREALLOCATED_VUS, 100),
      maxVUs: num(__ENV.MAX_VUS, 2000),
      exec: 'default',
    },
  };
}

// Percentiles to compute in the end-of-test summary. k6's default is only
// p(90)/p(95); the methodology calls for p50–p99.9, so request them explicitly.
export const SUMMARY_TREND_STATS = ['avg', 'min', 'med', 'p(50)', 'p(90)', 'p(95)', 'p(99)', 'p(99.9)', 'max'];

// ---- thresholds -----------------------------------------------------------
// For saturation (abort=true) the breakpoint is driven by LATENCY (p99): the
// knee where the server stops keeping up is the real "max sustainable throughput"
// signal. We deliberately do NOT abort on http_req_failed: it's a *cumulative*
// rate, so a single transient connection reset early in the ramp (~1/500 reqs =
// 0.2%) would falsely trip the 0.1% SLO and abort at a bogus rate. The error rate
// is still measured and thresholded (so it shows in the report / fails the SLO
// line), just not used to abort the ramp.
export function thresholds(abort = false) {
  return {
    http_req_duration: [{ threshold: `p(99)<${P99_MS}`, abortOnFail: abort, delayAbortEval: '15s' }],
    http_req_failed: [`rate<${MAX_ERROR_RATE}`],
    fhir_errors: [`rate<${MAX_ERROR_RATE}`],
  };
}

// Re-host an absolute URL onto BASE's origin. FHIR servers emit ABSOLUTE
// Bundle.link[next] URLs built from their configured base (e.g. http://localhost:9090
// /fhir/r4/...), which is NOT the address the load generator uses to reach the SUT
// (private IP). Following them verbatim dials the wrong host -> "connection refused".
// Keep the server's opaque continuation query; swap in the origin we actually use.
function rehost(absUrl) {
  const baseOrigin = BASE.match(/^https?:\/\/[^/]+/)[0];      // scheme://host:port of BASE
  const path = String(absUrl).replace(/^https?:\/\/[^/]+/, ''); // /fhir/r4/...?token
  return baseOrigin + path;
}

// ---- setup: build a pool of real resource ids to read --------------------
// Pages the server's own API (no external id file) so reads hit existing data.
export function collectIds(resourceType, want) {
  const ids = [];
  let url = `${BASE}/${resourceType}?_count=100&_elements=id`;
  let guard = 0;
  while (url && ids.length < want && guard < 200) {
    guard++;
    const res = http.get(url, { headers: JSON_HEADERS });
    if (res.status !== 200) break;
    const bundle = res.json();
    for (const e of (bundle.entry || [])) {
      if (e.resource && e.resource.id) ids.push(e.resource.id);
      if (ids.length >= want) break;
    }
    const next = (bundle.link || []).find((l) => l.relation === 'next');
    url = next ? rehost(next.url) : null;   // route pagination to the reachable host
  }
  return ids;
}

export function randItem(arr) {
  return arr[Math.floor(Math.random() * arr.length)];
}

// Minimal, dependency-free end-of-test summary: write the full data object as
// JSON (the orchestrator captures it as an artifact) plus a short stdout line.
export function summary(scenarioName) {
  return function handleSummary(data) {
    const out = {};
    const file = __ENV.SUMMARY_OUT || `summary-${scenarioName}.json`;
    out[file] = JSON.stringify(data, null, 2);
    const m = data.metrics || {};
    const dur = m.http_req_duration && m.http_req_duration.values ? m.http_req_duration.values : {};
    const failed = m.http_req_failed && m.http_req_failed.values ? m.http_req_failed.values : {};
    const p50 = dur['p(50)'] !== undefined ? dur['p(50)'] : (dur.med || 0);
    out.stdout =
      `\n${scenarioName}: ` +
      `reqs=${(m.http_reqs && m.http_reqs.values.count) || 0} ` +
      `rate=${((m.http_reqs && m.http_reqs.values.rate) || 0).toFixed(1)}/s ` +
      `p50=${p50.toFixed(1)}ms ` +
      `p99=${(dur['p(99)'] || 0).toFixed(1)}ms ` +
      `p99.9=${(dur['p(99.9)'] || 0).toFixed(1)}ms ` +
      `err=${(((failed.rate) || 0) * 100).toFixed(3)}%\n`;
    return out;
  };
}
