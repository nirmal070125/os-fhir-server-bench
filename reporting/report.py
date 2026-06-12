#!/usr/bin/env python3
"""Generate the comparison report from results/.

Reads every results/<server>/run-manifest.json and the per-rep k6 summaries at
results/<server>/<scenario>/rep-*/summary.json, aggregates across repetitions
(median + min/max), and writes:

  results/report.md   human-readable comparison (one table per scenario)
  results/report.csv  flat rows for any downstream analysis

Fairness metric = throughput per vCPU (measured req/s ÷ sut_cpus from the manifest),
so servers given the same CPU envelope are compared on equal footing. SLO pass/fail
uses the manifest's slo (p99_ms AND max_error_rate). No third-party deps — stdlib only.
"""
import csv
import json
import os
import statistics
import sys
from pathlib import Path

ROOT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
RESULTS = ROOT / "results"


def load(p):
    with open(p) as f:
        return json.load(f)


def trend(metric):
    """Return the .values dict of a k6 trend metric, or {}."""
    return (metric or {}).get("values", {}) if metric else {}


def rep_row(summary):
    """Extract the numbers we care about from one rep's k6 summary."""
    m = summary.get("metrics", {})
    dur = trend(m.get("http_req_duration"))
    reqs = (m.get("http_reqs") or {}).get("values", {})
    failed = (m.get("http_req_failed") or {}).get("values", {})
    p50 = dur.get("p(50)", dur.get("med", 0.0))
    return {
        "rate": reqs.get("rate", 0.0),
        "count": reqs.get("count", 0),
        "p50": p50,
        "p95": dur.get("p(95)", 0.0),
        "p99": dur.get("p(99)", 0.0),
        "p99_9": dur.get("p(99.9)", 0.0),
        "err": failed.get("rate", 0.0),
        "dur_s": summary.get("state", {}).get("testRunDurationMs", 0.0) / 1000.0,
    }


def parse_dur(s):
    """'30s' -> 30.0, '5m' -> 300.0 (Go-ish duration; seconds/minutes only)."""
    s = str(s).strip()
    if s.endswith("ms"):
        return float(s[:-2]) / 1000.0
    if s.endswith("m"):
        return float(s[:-1]) * 60.0
    if s.endswith("s"):
        return float(s[:-1])
    return float(s)


def max_sustainable(dur_s, ramp):
    """Max sustainable throughput from a saturation rep.

    saturation ramps the offered rate up and aborts (abortOnFail) ~abort_delay_s
    after p99/error first breaches the SLO, so the run duration tells us which ramp
    stage it reached -> the offered rate just before the breach. Returns
    (rate_req_s, capped) where capped=True means it never breached (sustained the
    whole ramp, so the true ceiling is >= max_rate). Measurement is untouched; this
    is pure post-processing of the run duration.
    """
    start, step, maxr = ramp["start_rate"], ramp["step_rate"], ramp["max_rate"]
    step_dur = parse_dur(ramp["step_duration"])
    abort = ramp.get("abort_delay_s", 10)
    n_stages = (maxr - start) // step + 1
    full = n_stages * step_dur
    if dur_s >= full * 0.98:           # ran the whole ramp without breaching
        return (maxr, True)
    stage = max(0, int((dur_s - abort) // step_dur))
    return (min(maxr, start + step * stage), False)


def agg(vals):
    """median, min, max across reps (median is what we headline)."""
    if not vals:
        return (0.0, 0.0, 0.0)
    return (statistics.median(vals), min(vals), max(vals))


def discover():
    """server -> {manifest, scenarios{name -> [rep_row,...]}}"""
    out = {}
    if not RESULTS.exists():
        return out
    for mf in sorted(RESULTS.glob("*/run-manifest.json")):
        server = mf.parent.name
        manifest = load(mf)
        scenarios = {}
        for scen_dir in sorted(mf.parent.iterdir()):
            if not scen_dir.is_dir():
                continue
            reps = [rep_row(load(s)) for s in sorted(scen_dir.glob("rep-*/summary.json"))]
            if reps:
                scenarios[scen_dir.name] = reps
        out[server] = {"manifest": manifest, "scenarios": scenarios}
    return out


def fmt(x, unit=""):
    return f"{x:.1f}{unit}" if isinstance(x, float) else f"{x}{unit}"


def main():
    data = discover()
    if not data:
        print("no results found under results/ — run the benchmark first", file=sys.stderr)
        sys.exit(1)

    # provenance is taken from the first server's manifest (limits/slo/dataset are shared).
    any_m = next(iter(data.values()))["manifest"]
    slo = any_m.get("slo", {})
    p99_slo = slo.get("p99_ms", 500)
    err_slo = slo.get("max_error_rate", 0.001)
    p99_by_scen = slo.get("p99_ms_by_scenario", {})
    # Each scenario is judged against its own p99 bar (e.g. ingest writes are heavier).
    def p99_slo_for(scen):
        return p99_by_scen.get(scen, p99_slo)

    all_scenarios = sorted({s for v in data.values() for s in v["scenarios"]})

    md = []
    md.append("# Benchmark report\n")
    ds = any_m.get("dataset", {})
    lim = any_m.get("limits", {})
    seed_note = ""
    if ds.get("bundles_total"):
        ok_b, tot_b, fail_b = ds.get("bundles_ok", 0), ds["bundles_total"], ds.get("bundles_failed", 0)
        seed_note = f" — {ok_b:,}/{tot_b:,} bundles loaded" + (f" ({fail_b:,} failed at seed, {ds.get('success_pct','?')}%)" if fail_b else " (all)")
    md.append(
        f"- **Dataset:** {ds.get('size','?')} (hash `{str(ds.get('hash',''))[:12]}`){seed_note}  \n"
        f"- **Envelope (per server):** {lim.get('sut_cpus','?')} vCPU / {lim.get('sut_mem','?')} app, "
        f"{lim.get('db_cpus','?')} vCPU / {lim.get('db_mem','?')} db  \n"
        f"- **SLO:** error rate < {err_slo}; p99 < {p99_slo} ms (default/reads)"
        + (f", overrides: {', '.join(f'{k} {v}ms' for k, v in p99_by_scen.items() if v != p99_slo)}" if any(v != p99_slo for v in p99_by_scen.values()) else "")
        + " — per-table below  \n"
        f"- **Reps:** {any_m.get('run',{}).get('repetitions','?')} "
        f"(measure {any_m.get('run',{}).get('measure_s','?')}s, warm-up "
        f"{any_m.get('run',{}).get('warmup_s','?')}s discarded)  \n"
        f"- **k6:** {any_m.get('k6_version','?')}  ·  **bench commit:** {any_m.get('bench_repo_sha','?')}\n"
    )

    csv_rows = []
    for scen in all_scenarios:
        md.append(f"\n## {scen}\n")

        # saturation reports MAX SUSTAINABLE THROUGHPUT (offered rate at SLO breach),
        # not pass/fail — a ramp is meant to breach the SLO at its top step.
        if scen == "saturation":
            md.append("| Server | Max sustainable (req/s) | per vCPU | aggregate p99 (ms) | Error rate |")
            md.append("|---|---|---|---|---|")
            sat = []
            for server, v in data.items():
                reps = v["scenarios"].get(scen)
                if not reps:
                    continue
                cpus = v["manifest"].get("limits", {}).get("sut_cpus", 1) or 1
                ramp = v["manifest"].get("saturation_ramp")
                if not ramp:
                    continue  # older manifest without ramp params
                rates, capped = [], False
                for r in reps:
                    rate, cap = max_sustainable(r["dur_s"], ramp)
                    rates.append(rate)
                    capped = capped or cap
                ms_med = statistics.median(rates)
                p99_med, _, _ = agg([r["p99"] for r in reps])
                err_med, _, _ = agg([r["err"] for r in reps])
                sat.append((ms_med, server, cpus, ms_med, capped, p99_med, err_med))
            sat.sort(reverse=True)
            for (_, server, cpus, ms_med, capped, p99_med, err_med) in sat:
                label = f"≥ {ms_med:.0f} (no breach)" if capped else f"~{ms_med:.0f}"
                md.append(f"| {server} | {label} | {ms_med/cpus:.0f} | {p99_med:.1f} | {err_med*100:.3f}% |")
                csv_rows.append({
                    "scenario": scen, "server": server, "sut_cpus": cpus,
                    "throughput_rps": round(ms_med, 2),
                    "throughput_per_vcpu": round(ms_med / cpus, 2),
                    "p50_ms": "", "p95_ms": "",
                    "p99_ms": round(p99_med, 2), "p99_9_ms": "",
                    "error_rate": round(err_med, 6), "slo_pass": "max-sustainable",
                })
            continue

        scen_p99_slo = p99_slo_for(scen)
        md.append(f"_SLO: p99 < {scen_p99_slo} ms AND error rate < {err_slo}_\n")
        md.append("| Server | Throughput (req/s) | Thru/vCPU | p50 (ms) | p95 (ms) | p99 (ms) | p99.9 (ms) | Error rate | SLO |")
        md.append("|---|---|---|---|---|---|---|---|---|")
        # rank by median throughput desc
        ranked = []
        for server, v in data.items():
            reps = v["scenarios"].get(scen)
            if not reps:
                continue
            cpus = v["manifest"].get("limits", {}).get("sut_cpus", 1) or 1
            rate_med, _, _ = agg([r["rate"] for r in reps])
            p50_med, _, _ = agg([r["p50"] for r in reps])
            p95_med, _, _ = agg([r["p95"] for r in reps])
            p99_med, p99_lo, p99_hi = agg([r["p99"] for r in reps])
            p999_med, _, _ = agg([r["p99_9"] for r in reps])
            err_med, _, err_hi = agg([r["err"] for r in reps])
            passed = (p99_med < scen_p99_slo) and (err_hi < err_slo)
            ranked.append((rate_med, server, cpus, rate_med, p50_med, p95_med,
                           p99_med, p99_lo, p99_hi, p999_med, err_med, passed))
        ranked.sort(reverse=True)
        for (_, server, cpus, rate_med, p50_med, p95_med, p99_med, p99_lo, p99_hi,
             p999_med, err_med, passed) in ranked:
            md.append(
                f"| {server} | {rate_med:.1f} | {rate_med/cpus:.1f} | {p50_med:.1f} | "
                f"{p95_med:.1f} | {p99_med:.1f} (±{(p99_hi-p99_lo)/2:.1f}) | {p999_med:.1f} | "
                f"{err_med*100:.3f}% | {'✅ PASS' if passed else '❌ FAIL'} |"
            )
            csv_rows.append({
                "scenario": scen, "server": server, "sut_cpus": cpus,
                "throughput_rps": round(rate_med, 2),
                "throughput_per_vcpu": round(rate_med / cpus, 2),
                "p50_ms": round(p50_med, 2), "p95_ms": round(p95_med, 2),
                "p99_ms": round(p99_med, 2), "p99_9_ms": round(p999_med, 2),
                "error_rate": round(err_med, 6), "slo_pass": passed,
            })

    md.append("\n> Throughput/error are medians across reps; p99 shows ±half-spread. "
              "Throughput/vCPU is the fairness-normalized headline. "
              "**saturation** reports max sustainable throughput — the offered rate just "
              "before p99/error breached the SLO (`≥ X (no breach)` means it sustained the "
              "whole ramp); its p99 is the aggregate over the full ramp, expected to be high.\n")

    report_md = RESULTS / "report.md"
    report_md.write_text("\n".join(md) + "\n")
    with open(RESULTS / "report.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(csv_rows[0].keys()) if csv_rows else
                           ["scenario", "server"])
        w.writeheader()
        w.writerows(csv_rows)

    print(f"wrote {report_md}")
    print(f"wrote {RESULTS / 'report.csv'}")
    # echo the report to stdout so a CI log / headless run shows it
    print("\n" + report_md.read_text())


if __name__ == "__main__":
    main()
