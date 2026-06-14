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
// Two load models, selected by LOAD_MODEL (default: closed). Both sweep a ladder of
// levels (one level per run); the orchestrator steps the ladder. See docs/load-model.md.
//
// CLOSED (default) — VUS concurrent clients, each looping send -> await reply -> send
// next (no think-time). Concurrency is the INPUT; throughput is the measured output.
// This is the field-standard "N concurrent users" shape and is directly comparable to
// published FHIR-server benchmarks. No VU pool to exhaust -> no dropped-iteration
// artifact. (Tail latency reads optimistically past saturation — coordinated omission
// — so report throughput as the headline and treat near-cliff p99 as indicative.)
export function constantVus(name) {
  return {
    [name]: {
      executor: 'constant-vus',
      vus: num(__ENV.VUS, 1),
      duration: __ENV.DURATION || '60s',
      exec: 'default',
    },
  };
}

// OPEN — k6 issues RATE iterations/sec on a clock, independent of server speed. The
// offered RATE is the input; a slow server piles up a backlog rather than throttling
// the load, so tail latency stays honest (no coordinated omission). run.sh sizes the
// VU pool from the rate; if it's exhausted (deep overload) k6 emits dropped_iterations,
// which report.py flags so the load generator's ceiling isn't mistaken for the server's.
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

// Pick the executor for the configured model (closed unless LOAD_MODEL=open).
export function executor(name) {
  return __ENV.LOAD_MODEL === 'open' ? constantArrival(name) : constantVus(name);
}

const OPEN = __ENV.LOAD_MODEL === 'open';

// Percentiles to compute in the end-of-test summary. k6's default is only
// p(90)/p(95); the methodology calls for p50–p99.9, so request them explicitly.
export const SUMMARY_TREND_STATS = ['avg', 'min', 'med', 'p(50)', 'p(90)', 'p(95)', 'p(99)', 'p(99.9)', 'max'];

// ---- thresholds -----------------------------------------------------------
// Pure pass/fail signal for the SLO line — never aborts. Each level runs to
// completion; report.py finds the knee and the highest level still under the p99 SLO
// from the measured numbers across the sweep.
export function thresholds() {
  return {
    http_req_duration: [`p(99)<${P99_MS}`],
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
    const dropped = m.dropped_iterations && m.dropped_iterations.values ? (m.dropped_iterations.values.count || 0) : 0;
    const p50 = dur['p(50)'] !== undefined ? dur['p(50)'] : (dur.med || 0);
    const level = OPEN ? `offered=${__ENV.RATE || '?'}/s` : `vus=${__ENV.VUS || '?'}`;
    out.stdout =
      `\n${scenarioName}: ` +
      `${level} ` +
      `achieved=${((m.http_reqs && m.http_reqs.values.rate) || 0).toFixed(1)}/s ` +
      `p50=${p50.toFixed(1)}ms ` +
      `p99=${(dur['p(99)'] || 0).toFixed(1)}ms ` +
      `p99.9=${(dur['p(99.9)'] || 0).toFixed(1)}ms ` +
      `err=${(((failed.rate) || 0) * 100).toFixed(3)}% ` +
      `dropped=${dropped}\n`;
    return out;
  };
}
