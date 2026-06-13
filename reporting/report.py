#!/usr/bin/env python3
"""Generate the comparison report from results/.

Open model: each workload is swept across a ladder of offered rates (req/s, k6
constant-arrival-rate). Reads every results/<server>/run-manifest.json and the
per-level k6 summaries at results/<server>/<scenario>/rep-*/rate-*/summary.json,
aggregates across repetitions (median + min/max) per offered rate, and writes:

  results/report.md   human-readable comparison: a headline (max sustainable
                      throughput) + a latency-vs-rate curve per server, per scenario
  results/report.csv  one row per (scenario, server, offered_rate) for plotting

Headline = MAX SUSTAINABLE THROUGHPUT: the highest offered rate the server keeps up
with (achieved ≈ offered, no dropped iterations) while p99 < SLO and errors < max.
Open model keeps tail latency honest (no coordinated omission); dropped_iterations
flags any level where the LOAD GENERATOR couldn't deliver the offered rate, so its
ceiling is never mistaken for the server's. Fairness metric = throughput per vCPU
(÷ sut_cpus from the manifest). No third-party deps — stdlib only.
"""
import csv
import json
import statistics
import sys
from pathlib import Path

ROOT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
RESULTS = ROOT / "results"

# A level "kept up" if it delivered at least this fraction of the offered rate.
DELIVERED_FRAC = 0.95


def load(p):
    with open(p) as f:
        return json.load(f)


def trend(metric):
    """Return the .values dict of a k6 trend metric, or {}."""
    return (metric or {}).get("values", {}) if metric else {}


def rep_row(summary):
    """Extract the numbers we care about from one rep's k6 summary at one rate."""
    m = summary.get("metrics", {})
    dur = trend(m.get("http_req_duration"))
    reqs = (m.get("http_reqs") or {}).get("values", {})
    failed = (m.get("http_req_failed") or {}).get("values", {})
    dropped = (m.get("dropped_iterations") or {}).get("values", {})
    p50 = dur.get("p(50)", dur.get("med", 0.0))
    return {
        "achieved": reqs.get("rate", 0.0),   # measured completed throughput (req/s)
        "p50": p50,
        "p95": dur.get("p(95)", 0.0),
        "p99": dur.get("p(99)", 0.0),
        "p99_9": dur.get("p(99.9)", 0.0),
        "err": failed.get("rate", 0.0),
        "dropped": dropped.get("count", 0),
    }


def agg(vals):
    """median, min, max across reps (median is what we headline)."""
    if not vals:
        return (0.0, 0.0, 0.0)
    return (statistics.median(vals), min(vals), max(vals))


def discover():
    """server -> {manifest, scenarios{name -> {offered_rate:int -> [rep_row,...]}}}"""
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
            levels = {}  # offered_rate -> [rep_row, ...]
            for r_dir in sorted(scen_dir.glob("rep-*/rate-*")):
                try:
                    rate = int(r_dir.name.split("-", 1)[1])
                except (IndexError, ValueError):
                    continue
                sfile = r_dir / "summary.json"
                if sfile.exists():
                    levels.setdefault(rate, []).append(rep_row(load(sfile)))
            if levels:
                scenarios[scen_dir.name] = levels
        out[server] = {"manifest": manifest, "scenarios": scenarios}
    return out


def level_stats(offered, reps):
    """Median (+ spread) across reps for one offered-rate level."""
    ach_med, ach_lo, ach_hi = agg([r["achieved"] for r in reps])
    dropped_max = max((r["dropped"] for r in reps), default=0)
    return {
        "offered": offered,
        "ach_med": ach_med, "ach_lo": ach_lo, "ach_hi": ach_hi,
        "p50": agg([r["p50"] for r in reps])[0],
        "p95": agg([r["p95"] for r in reps])[0],
        "p99": agg([r["p99"] for r in reps])[0],
        "p99_9": agg([r["p99_9"] for r in reps])[0],
        "err_med": agg([r["err"] for r in reps])[0],
        "err_hi": agg([r["err"] for r in reps])[2],
        "dropped": dropped_max,
        # "kept up": delivered the offered rate without dropping iterations
        "delivered": dropped_max == 0 and ach_med >= DELIVERED_FRAC * offered,
    }


def main():
    data = discover()
    if not data:
        print("no results found under results/ — run the benchmark first", file=sys.stderr)
        sys.exit(1)

    any_m = next(iter(data.values()))["manifest"]
    slo = any_m.get("slo", {})
    p99_slo = slo.get("p99_ms", 500)
    err_slo = slo.get("max_error_rate", 0.001)
    p99_by_scen = slo.get("p99_ms_by_scenario", {})

    def p99_slo_for(scen):
        return p99_by_scen.get(scen, p99_slo)

    def passes(s, scen_p99_slo):
        return s["delivered"] and s["p99"] < scen_p99_slo and s["err_hi"] < err_slo

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
        f"- **Load model:** {any_m.get('load_model','open (constant-arrival-rate sweep)')} — "
        f"offered rate (req/s) is swept; tail latency is coordinated-omission-free  \n"
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
            f"_Open model — offered rate (req/s k6 issues on a clock) is swept. "
            f"**Achieved** is the server's completed throughput: ≈ offered while it keeps "
            f"up, less once it can't. Latency is coordinated-omission-free. `dropped` > 0 "
            f"means the load generator couldn't deliver the offered rate (server saturated). "
            f"SLO: p99 < {scen_p99_slo} ms AND error rate < {err_slo} AND offered rate "
            f"delivered._\n"
        )

        # per-server level stats (sorted by offered rate)
        server_levels = {}
        for server, v in data.items():
            levels = v["scenarios"].get(scen)
            if not levels:
                continue
            cpus = v["manifest"].get("limits", {}).get("sut_cpus", 1) or 1
            rows = [level_stats(r, levels[r]) for r in sorted(levels)]
            server_levels[server] = {"cpus": cpus, "levels": rows}

        # ---- headline: max sustainable throughput -----------------------------------
        md.append("### Max sustainable throughput\n")
        md.append("| Server | Max sustainable (req/s) | per vCPU | p99 there (ms) | Error rate |")
        md.append("|---|---|---|---|---|")
        headline = []
        for server, sl in server_levels.items():
            cpus, rows = sl["cpus"], sl["levels"]
            ok = [s for s in rows if passes(s, scen_p99_slo)]
            if not ok:
                # never sustained even the lowest offered rate under SLO
                headline.append((-1.0, server, cpus, "— (SLO missed at lowest rate)", 0.0, 0.0))
                continue
            best = max(ok, key=lambda s: s["offered"])
            never_breached = best is rows[-1]
            label = f"≥ {best['offered']:.0f} (no breach)" if never_breached else f"{best['offered']:.0f}"
            headline.append((best["offered"], server, cpus, label, best["p99"], best["err_med"]))
        headline.sort(reverse=True)
        for (sortkey, server, cpus, label, p99v, errv) in headline:
            per_vcpu = f"{sortkey/cpus:.0f}" if sortkey > 0 else "—"
            md.append(f"| {server} | {label} | {per_vcpu} | {p99v:.1f} | {errv*100:.3f}% |")

        # ---- per-server latency-vs-rate curve ---------------------------------------
        for server, sl in server_levels.items():
            cpus, rows = sl["cpus"], sl["levels"]
            md.append(f"\n### {server} — latency vs offered rate\n")
            md.append("| Offered (req/s) | Achieved (req/s) | Ach/vCPU | p50 (ms) | p95 (ms) | p99 (ms) | p99.9 (ms) | Error rate | Dropped | SLO |")
            md.append("|---|---|---|---|---|---|---|---|---|---|")
            for s in rows:
                ok = passes(s, scen_p99_slo)
                spread = (s["ach_hi"] - s["ach_lo"]) / 2
                drop_cell = f"{s['dropped']:.0f}" if s["dropped"] else "0"
                md.append(
                    f"| {s['offered']:.0f} | {s['ach_med']:.1f} (±{spread:.1f}) | {s['ach_med']/cpus:.1f} | "
                    f"{s['p50']:.1f} | {s['p95']:.1f} | {s['p99']:.1f} | {s['p99_9']:.1f} | "
                    f"{s['err_med']*100:.3f}% | {drop_cell} | {'✅' if ok else '❌'} |"
                )
                csv_rows.append({
                    "scenario": scen, "server": server, "sut_cpus": cpus,
                    "offered_rps": s["offered"],
                    "achieved_rps": round(s["ach_med"], 2),
                    "achieved_per_vcpu": round(s["ach_med"] / cpus, 2),
                    "p50_ms": round(s["p50"], 2), "p95_ms": round(s["p95"], 2),
                    "p99_ms": round(s["p99"], 2), "p99_9_ms": round(s["p99_9"], 2),
                    "error_rate": round(s["err_med"], 6),
                    "dropped_iterations": int(s["dropped"]),
                    "slo_pass": ok,
                })

    md.append(
        "\n> Achieved throughput is the median across reps (±half-spread); per-vCPU is the "
        "fairness-normalized view. **Max sustainable throughput** is the highest offered "
        "rate the server delivered while keeping p99 under the SLO (`≥ X (no breach)` means "
        "it sustained the whole ladder — raise the ladder to find the real ceiling). Latency "
        "is coordinated-omission-free (open model); a non-zero `Dropped` column means the "
        "load generator hit its VU ceiling at that rate (server already saturated) — see "
        "docs/load-model.md.\n"
    )

    report_md = RESULTS / "report.md"
    report_md.write_text("\n".join(md) + "\n")
    with open(RESULTS / "report.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(csv_rows[0].keys()) if csv_rows else
                           ["scenario", "server", "offered_rps"])
        w.writeheader()
        w.writerows(csv_rows)

    print(f"wrote {report_md}")
    print(f"wrote {RESULTS / 'report.csv'}")
    print("\n" + report_md.read_text())


if __name__ == "__main__":
    main()
