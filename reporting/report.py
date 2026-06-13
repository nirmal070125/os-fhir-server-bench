#!/usr/bin/env python3
"""Generate the comparison report from results/.

Closed model: each workload is swept across a ladder of concurrency levels (k6 VUs).
Reads every results/<server>/run-manifest.json and the per-level k6 summaries at
results/<server>/<scenario>/rep-*/c-*/summary.json, aggregates across repetitions
(median + min/max) per concurrency level, and writes:

  results/report.md   human-readable comparison: a headline table + a
                      throughput-vs-concurrency curve per server, per scenario
  results/report.csv  one row per (scenario, server, concurrency) for plotting

Fairness metric = throughput per vCPU (measured req/s ÷ sut_cpus from the manifest),
so servers given the same CPU envelope are compared on equal footing. Throughput is
coordinated-omission-immune; latency percentiles are closed-model per-request values
(see docs/load-model.md). SLO pass/fail uses the manifest's slo (p99_ms AND
max_error_rate). No third-party deps — stdlib only.
"""
import csv
import json
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
    """Extract the numbers we care about from one rep's k6 summary at one level."""
    m = summary.get("metrics", {})
    dur = trend(m.get("http_req_duration"))
    reqs = (m.get("http_reqs") or {}).get("values", {})
    failed = (m.get("http_req_failed") or {}).get("values", {})
    p50 = dur.get("p(50)", dur.get("med", 0.0))
    return {
        "rate": reqs.get("rate", 0.0),     # measured throughput (req/s) — the headline
        "count": reqs.get("count", 0),
        "p50": p50,
        "p95": dur.get("p(95)", 0.0),
        "p99": dur.get("p(99)", 0.0),
        "p99_9": dur.get("p(99.9)", 0.0),
        "err": failed.get("rate", 0.0),
    }


def agg(vals):
    """median, min, max across reps (median is what we headline)."""
    if not vals:
        return (0.0, 0.0, 0.0)
    return (statistics.median(vals), min(vals), max(vals))


def discover():
    """server -> {manifest, scenarios{name -> {concurrency:int -> [rep_row,...]}}}"""
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
            levels = {}  # concurrency -> [rep_row, ...]
            for c_dir in sorted(scen_dir.glob("rep-*/c-*")):
                try:
                    c = int(c_dir.name.split("-", 1)[1])
                except (IndexError, ValueError):
                    continue
                sfile = c_dir / "summary.json"
                if sfile.exists():
                    levels.setdefault(c, []).append(rep_row(load(sfile)))
            if levels:
                scenarios[scen_dir.name] = levels
        out[server] = {"manifest": manifest, "scenarios": scenarios}
    return out


def level_stats(reps):
    """Median (+ throughput spread) across reps for one concurrency level."""
    thr_med, thr_lo, thr_hi = agg([r["rate"] for r in reps])
    return {
        "thr_med": thr_med, "thr_lo": thr_lo, "thr_hi": thr_hi,
        "p50": agg([r["p50"] for r in reps])[0],
        "p95": agg([r["p95"] for r in reps])[0],
        "p99": agg([r["p99"] for r in reps])[0],
        "p99_9": agg([r["p99_9"] for r in reps])[0],
        "err_med": agg([r["err"] for r in reps])[0],
        "err_hi": agg([r["err"] for r in reps])[2],
    }


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
        f"- **Load model:** {any_m.get('load_model','closed (constant-vus concurrency sweep)')} — "
        f"concurrency (in-flight clients) is swept; throughput is the measured output  \n"
        f"- **Dataset:** {ds.get('size','?')} (hash `{str(ds.get('hash',''))[:12]}`){seed_note}  \n"
        f"- **Envelope (per server):** {lim.get('sut_cpus','?')} vCPU / {lim.get('sut_mem','?')} app, "
        f"{lim.get('db_cpus','?')} vCPU / {lim.get('db_mem','?')} db  \n"
        f"- **SLO:** error rate < {err_slo}; p99 < {p99_slo} ms (default/reads)"
        + (f", overrides: {', '.join(f'{k} {v}ms' for k, v in p99_by_scen.items() if v != p99_slo)}" if any(v != p99_slo for v in p99_by_scen.values()) else "")
        + "  \n"
        f"- **Reps:** {any_m.get('run',{}).get('repetitions','?')} "
        f"(measure {any_m.get('run',{}).get('measure_s','?')}s/level, warm-up "
        f"{any_m.get('run',{}).get('warmup_s','?')}s discarded)  \n"
        f"- **k6:** {any_m.get('k6_version','?')}  ·  **bench commit:** {any_m.get('bench_repo_sha','?')}\n"
    )

    csv_rows = []
    for scen in all_scenarios:
        scen_p99_slo = p99_slo_for(scen)
        md.append(f"\n## {scen}\n")
        md.append(
            f"_Closed model — concurrency = number of in-flight clients (k6 VUs). "
            f"**Throughput** is the measured output (coordinated-omission-immune). "
            f"Latency columns are **closed-model per-request percentiles** (optimistic "
            f"once a server is past its knee). SLO: p99 < {scen_p99_slo} ms AND error rate "
            f"< {err_slo}._\n"
        )

        # ---- per-server level stats -------------------------------------------------
        server_levels = {}  # server -> {cpus, levels: [(c, stats), ...] sorted by c}
        for server, v in data.items():
            levels = v["scenarios"].get(scen)
            if not levels:
                continue
            cpus = v["manifest"].get("limits", {}).get("sut_cpus", 1) or 1
            rows = [(c, level_stats(levels[c])) for c in sorted(levels)]
            server_levels[server] = {"cpus": cpus, "levels": rows}

        # ---- headline: peak throughput + max throughput under SLO -------------------
        md.append("### Headline\n")
        md.append("| Server | Peak throughput | Peak/vCPU | Max throughput @ p99<SLO |")
        md.append("|---|---|---|---|")
        headline = []
        for server, sl in server_levels.items():
            cpus, rows = sl["cpus"], sl["levels"]
            peak_c, peak = max(rows, key=lambda cr: cr[1]["thr_med"])
            under = [(c, s) for (c, s) in rows if s["p99"] < scen_p99_slo and s["err_hi"] < err_slo]
            if under:
                slo_c, slo_s = max(under, key=lambda cr: cr[1]["thr_med"])
                slo_cell = f"{slo_s['thr_med']:.0f} @ C={slo_c}"
            else:
                slo_cell = "— (no level met SLO)"
            headline.append((peak["thr_med"], server, peak_c, cpus, slo_cell))
        headline.sort(reverse=True)
        for (peak_thr, server, peak_c, cpus, slo_cell) in headline:
            md.append(f"| {server} | {peak_thr:.0f} req/s @ C={peak_c} | {peak_thr/cpus:.0f} | {slo_cell} |")

        # ---- per-server throughput-vs-concurrency curve -----------------------------
        for server, sl in server_levels.items():
            cpus, rows = sl["cpus"], sl["levels"]
            md.append(f"\n### {server} — throughput vs concurrency\n")
            md.append("| Concurrency | Throughput (req/s) | Thru/vCPU | p50 (ms) | p95 (ms) | p99 (ms) | p99.9 (ms) | Error rate | SLO |")
            md.append("|---|---|---|---|---|---|---|---|---|")
            for (c, s) in rows:
                passed = (s["p99"] < scen_p99_slo) and (s["err_hi"] < err_slo)
                spread = (s["thr_hi"] - s["thr_lo"]) / 2
                md.append(
                    f"| {c} | {s['thr_med']:.1f} (±{spread:.1f}) | {s['thr_med']/cpus:.1f} | "
                    f"{s['p50']:.1f} | {s['p95']:.1f} | {s['p99']:.1f} | {s['p99_9']:.1f} | "
                    f"{s['err_med']*100:.3f}% | {'✅' if passed else '❌'} |"
                )
                csv_rows.append({
                    "scenario": scen, "server": server, "sut_cpus": cpus,
                    "concurrency": c,
                    "throughput_rps": round(s["thr_med"], 2),
                    "throughput_per_vcpu": round(s["thr_med"] / cpus, 2),
                    "p50_ms": round(s["p50"], 2), "p95_ms": round(s["p95"], 2),
                    "p99_ms": round(s["p99"], 2), "p99_9_ms": round(s["p99_9"], 2),
                    "error_rate": round(s["err_med"], 6), "slo_pass": passed,
                })

    md.append(
        "\n> Throughput is the median across reps (±half-spread); Throughput/vCPU is the "
        "fairness-normalized headline. **Peak throughput** is the server's capacity (the "
        "knee of the curve); **Max throughput @ p99<SLO** is the highest concurrency still "
        "under the latency bar. Latency percentiles are closed-model per-request values — "
        "trustworthy below the knee, optimistic above it (coordinated omission); see "
        "docs/load-model.md.\n"
    )

    report_md = RESULTS / "report.md"
    report_md.write_text("\n".join(md) + "\n")
    with open(RESULTS / "report.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(csv_rows[0].keys()) if csv_rows else
                           ["scenario", "server", "concurrency"])
        w.writeheader()
        w.writerows(csv_rows)

    print(f"wrote {report_md}")
    print(f"wrote {RESULTS / 'report.csv'}")
    # echo the report to stdout so a CI log / headless run shows it
    print("\n" + report_md.read_text())


if __name__ == "__main__":
    main()
