#!/usr/bin/env python3
"""Generate the comparison report from results/.

Supports both load models (run-manifest "load_model"):

  closed (default): each workload is swept across a ladder of CONCURRENCY levels
      (k6 constant-vus). Concurrency is the input; THROUGHPUT is the measured output.
      Headline = peak throughput + max throughput while p99 < SLO. Field-standard,
      comparable to published FHIR benchmarks. (Tail latency past saturation is
      optimistic — coordinated omission — so throughput is the headline.)

  open: swept across OFFERED RATES (k6 constant-arrival-rate). Headline = max
      sustainable throughput (highest offered rate delivered with p99 < SLO and no
      dropped iterations). Tail latency is coordinated-omission-free.

Reads results/<server>/run-manifest.json + the per-level summaries at
results/<server>/<scenario>/rep-*/{c,rate,lvl}-*/summary.json, aggregates across reps
(median + spread), and writes results/report.md and results/report.csv. Fairness metric
= throughput per vCPU (÷ sut_cpus). No third-party deps — stdlib only.
"""
import csv
import json
import statistics
import sys
from pathlib import Path

ROOT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
RESULTS = ROOT / "results"

DELIVERED_FRAC = 0.95          # open model: a level "kept up" if achieved ≥ this × offered
LEVEL_PREFIXES = ("c-", "rate-", "lvl-")


def load(p):
    with open(p) as f:
        return json.load(f)


def trend(metric):
    return (metric or {}).get("values", {}) if metric else {}


def rep_row(summary):
    """Numbers from one rep's k6 summary at one level."""
    m = summary.get("metrics", {})
    dur = trend(m.get("http_req_duration"))
    reqs = (m.get("http_reqs") or {}).get("values", {})
    failed = (m.get("http_req_failed") or {}).get("values", {})
    dropped = (m.get("dropped_iterations") or {}).get("values", {})
    return {
        "achieved": reqs.get("rate", 0.0),   # measured completed throughput (req/s)
        "p50": dur.get("p(50)", dur.get("med", 0.0)),
        "p95": dur.get("p(95)", 0.0),
        "p99": dur.get("p(99)", 0.0),
        "p99_9": dur.get("p(99.9)", 0.0),
        "err": failed.get("rate", 0.0),
        "dropped": dropped.get("count", 0),
    }


def agg(vals):
    if not vals:
        return (0.0, 0.0, 0.0)
    return (statistics.median(vals), min(vals), max(vals))


def model_of(manifest):
    return "open" if "open" in str(manifest.get("load_model", "closed")).lower() else "closed"


def parse_level(dirname):
    for pfx in LEVEL_PREFIXES:
        if dirname.startswith(pfx):
            try:
                return int(dirname[len(pfx):])
            except ValueError:
                return None
    return None


def discover():
    """server -> {manifest, model, scenarios{name -> {level:int -> [rep_row,...]}}}"""
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
            levels = {}
            for d in sorted(scen_dir.glob("rep-*/*")):
                lvl = parse_level(d.name) if d.is_dir() else None
                if lvl is None:
                    continue
                sfile = d / "summary.json"
                if sfile.exists():
                    levels.setdefault(lvl, []).append(rep_row(load(sfile)))
            if levels:
                scenarios[scen_dir.name] = levels
        out[server] = {"manifest": manifest, "model": model_of(manifest), "scenarios": scenarios}
    return out


def level_stats(level, reps, model):
    ach_med, ach_lo, ach_hi = agg([r["achieved"] for r in reps])
    dropped_max = max((r["dropped"] for r in reps), default=0)
    s = {
        "level": level,
        "ach_med": ach_med, "ach_lo": ach_lo, "ach_hi": ach_hi,
        "p50": agg([r["p50"] for r in reps])[0],
        "p95": agg([r["p95"] for r in reps])[0],
        "p99": agg([r["p99"] for r in reps])[0],
        "p99_9": agg([r["p99_9"] for r in reps])[0],
        "err_med": agg([r["err"] for r in reps])[0],
        "err_hi": agg([r["err"] for r in reps])[2],
        "dropped": dropped_max,
    }
    # closed: concurrency is the input, no dropped-iteration concept → always "delivered".
    # open: a level counts only if it delivered the offered rate without dropping.
    s["delivered"] = True if model == "closed" else (dropped_max == 0 and ach_med >= DELIVERED_FRAC * level)
    return s


def main():
    data = discover()
    if not data:
        print("no results found under results/ — run the benchmark first", file=sys.stderr)
        sys.exit(1)

    any_m = next(iter(data.values()))["manifest"]
    model = next(iter(data.values()))["model"]
    slo = any_m.get("slo", {})
    p99_slo = slo.get("p99_ms", 500)
    err_slo = slo.get("max_error_rate", 0.001)
    p99_by_scen = slo.get("p99_ms_by_scenario", {})

    def p99_slo_for(scen):
        return p99_by_scen.get(scen, p99_slo)

    def passes(s, scen_p99_slo):
        return s["delivered"] and s["p99"] < scen_p99_slo and s["err_hi"] < err_slo

    all_scenarios = sorted({s for v in data.values() for s in v["scenarios"]})

    md = ["# Benchmark report\n"]
    ds = any_m.get("dataset", {})
    lim = any_m.get("limits", {})
    seed_note = ""
    if ds.get("bundles_total"):
        ok_b, tot_b, fail_b = ds.get("bundles_ok", 0), ds["bundles_total"], ds.get("bundles_failed", 0)
        seed_note = f" — {ok_b:,}/{tot_b:,} bundles loaded" + (f" ({fail_b:,} failed at seed, {ds.get('success_pct','?')}%)" if fail_b else " (all)")
    model_desc = ("closed (constant-vus) — concurrency is swept; throughput is the measured output"
                  if model == "closed" else
                  "open (constant-arrival-rate) — offered rate is swept; tail latency is coordinated-omission-free")
    md.append(
        f"- **Load model:** {model_desc}  \n"
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

        server_levels = {}
        for server, v in data.items():
            levels = v["scenarios"].get(scen)
            if not levels:
                continue
            cpus = v["manifest"].get("limits", {}).get("sut_cpus", 1) or 1
            rows = [level_stats(lvl, levels[lvl], model) for lvl in sorted(levels)]
            server_levels[server] = {"cpus": cpus, "levels": rows}

        if model == "closed":
            md.append(
                f"_Closed model — concurrency (in-flight clients, VUs) is swept; **throughput** "
                f"is the measured output (coordinated-omission-immune). SLO: p99 < {scen_p99_slo} ms "
                f"AND error rate < {err_slo}. Latency past the knee reads optimistically — treat "
                f"near-cliff tails as indicative._\n"
            )
            # headline: peak throughput + max throughput under SLO
            md.append("### Headline\n")
            md.append("| Server | Peak throughput | Peak/vCPU | Max throughput @ p99<SLO |")
            md.append("|---|---|---|---|")
            head = []
            for server, sl in server_levels.items():
                cpus, rows = sl["cpus"], sl["levels"]
                peak = max(rows, key=lambda s: s["ach_med"])
                under = [s for s in rows if passes(s, scen_p99_slo)]
                if under:
                    b = max(under, key=lambda s: s["ach_med"])
                    slo_cell = f"{b['ach_med']:.0f} @ C={b['level']}"
                else:
                    slo_cell = "— (no level met SLO)"
                head.append((peak["ach_med"], server, peak["level"], cpus, slo_cell))
            head.sort(reverse=True)
            for (pk, server, pk_c, cpus, slo_cell) in head:
                md.append(f"| {server} | {pk:.0f} req/s @ C={pk_c} | {pk/cpus:.0f} | {slo_cell} |")
            # per-server throughput-vs-concurrency
            for server, sl in server_levels.items():
                cpus, rows = sl["cpus"], sl["levels"]
                md.append(f"\n### {server} — throughput vs concurrency\n")
                md.append("| Concurrency | Throughput (req/s) | Thru/vCPU | p50 (ms) | p95 (ms) | p99 (ms) | p99.9 (ms) | Error rate | SLO |")
                md.append("|---|---|---|---|---|---|---|---|---|")
                for s in rows:
                    ok = passes(s, scen_p99_slo)
                    spread = (s["ach_hi"] - s["ach_lo"]) / 2
                    md.append(
                        f"| {s['level']} | {s['ach_med']:.1f} (±{spread:.1f}) | {s['ach_med']/cpus:.1f} | "
                        f"{s['p50']:.1f} | {s['p95']:.1f} | {s['p99']:.1f} | {s['p99_9']:.1f} | "
                        f"{s['err_med']*100:.3f}% | {'✅' if ok else '❌'} |"
                    )
                    csv_rows.append({
                        "scenario": scen, "server": server, "sut_cpus": cpus, "model": model,
                        "level": s["level"], "level_kind": "concurrency",
                        "throughput_rps": round(s["ach_med"], 2),
                        "throughput_per_vcpu": round(s["ach_med"] / cpus, 2),
                        "p50_ms": round(s["p50"], 2), "p95_ms": round(s["p95"], 2),
                        "p99_ms": round(s["p99"], 2), "p99_9_ms": round(s["p99_9"], 2),
                        "error_rate": round(s["err_med"], 6),
                        "dropped_iterations": int(s["dropped"]), "slo_pass": ok,
                    })
        else:
            md.append(
                f"_Open model — offered rate (req/s on a clock) is swept. **Achieved** is the "
                f"server's completed throughput: ≈ offered while it keeps up, less once it can't. "
                f"`dropped` > 0 means the load generator couldn't deliver the offered rate (server "
                f"saturated). SLO: p99 < {scen_p99_slo} ms AND error rate < {err_slo} AND rate delivered._\n"
            )
            md.append("### Max sustainable throughput\n")
            md.append("| Server | Max sustainable (req/s) | per vCPU | p99 there (ms) | Error rate |")
            md.append("|---|---|---|---|---|")
            head = []
            for server, sl in server_levels.items():
                cpus, rows = sl["cpus"], sl["levels"]
                ok = [s for s in rows if passes(s, scen_p99_slo)]
                if not ok:
                    head.append((-1.0, server, cpus, "— (SLO missed at lowest rate)", 0.0, 0.0))
                    continue
                b = max(ok, key=lambda s: s["level"])
                label = f"≥ {b['level']:.0f} (no breach)" if b is rows[-1] else f"{b['level']:.0f}"
                head.append((b["level"], server, cpus, label, b["p99"], b["err_med"]))
            head.sort(reverse=True)
            for (sortkey, server, cpus, label, p99v, errv) in head:
                per = f"{sortkey/cpus:.0f}" if sortkey > 0 else "—"
                md.append(f"| {server} | {label} | {per} | {p99v:.1f} | {errv*100:.3f}% |")
            for server, sl in server_levels.items():
                cpus, rows = sl["cpus"], sl["levels"]
                md.append(f"\n### {server} — latency vs offered rate\n")
                md.append("| Offered (req/s) | Achieved (req/s) | Ach/vCPU | p50 (ms) | p95 (ms) | p99 (ms) | p99.9 (ms) | Error rate | Dropped | SLO |")
                md.append("|---|---|---|---|---|---|---|---|---|---|")
                for s in rows:
                    ok = passes(s, scen_p99_slo)
                    spread = (s["ach_hi"] - s["ach_lo"]) / 2
                    md.append(
                        f"| {s['level']} | {s['ach_med']:.1f} (±{spread:.1f}) | {s['ach_med']/cpus:.1f} | "
                        f"{s['p50']:.1f} | {s['p95']:.1f} | {s['p99']:.1f} | {s['p99_9']:.1f} | "
                        f"{s['err_med']*100:.3f}% | {int(s['dropped'])} | {'✅' if ok else '❌'} |"
                    )
                    csv_rows.append({
                        "scenario": scen, "server": server, "sut_cpus": cpus, "model": model,
                        "level": s["level"], "level_kind": "offered_rps",
                        "throughput_rps": round(s["ach_med"], 2),
                        "throughput_per_vcpu": round(s["ach_med"] / cpus, 2),
                        "p50_ms": round(s["p50"], 2), "p95_ms": round(s["p95"], 2),
                        "p99_ms": round(s["p99"], 2), "p99_9_ms": round(s["p99_9"], 2),
                        "error_rate": round(s["err_med"], 6),
                        "dropped_iterations": int(s["dropped"]), "slo_pass": ok,
                    })

    foot = ("\n> Throughput is the median across reps (±half-spread); per-vCPU is the "
            "fairness-normalized headline. ")
    if model == "closed":
        foot += ("**Peak throughput** is the knee/capacity; **Max throughput @ p99<SLO** is the "
                 "highest concurrency still under the bar. Closed-model latency is trustworthy below "
                 "the knee, optimistic above it (coordinated omission) — see docs/load-model.md.\n")
    else:
        foot += ("**Max sustainable throughput** is the highest offered rate delivered while p99 stayed "
                 "under the SLO (`≥ X (no breach)` = sustained the whole ladder). A non-zero `Dropped` "
                 "means the load generator saturated at that rate — see docs/load-model.md.\n")
    md.append(foot)

    report_md = RESULTS / "report.md"
    report_md.write_text("\n".join(md) + "\n")
    with open(RESULTS / "report.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(csv_rows[0].keys()) if csv_rows else
                           ["scenario", "server", "level"])
        w.writeheader()
        w.writerows(csv_rows)

    print(f"wrote {report_md}")
    print(f"wrote {RESULTS / 'report.csv'}")
    print("\n" + report_md.read_text())


if __name__ == "__main__":
    main()
