#!/usr/bin/env python3
"""Summarize llmdbenchmark results from the harness-agnostic benchmark reports.

Every harness except lm-eval writes one ``benchmark_report,_stage_<n>.yaml``
per workload stage (schema v0.2, see
https://github.com/llm-d/llm-d-benchmark/blob/main/docs/benchmark_report.md).
This script finds those files under a run directory
(``<workspace>/runner-<timestamp>``), a ``results/`` directory, or a single
experiment directory, and prints one row per stage:

  requests (total, failures), request rate, output and total token rate,
  TTFT p50/p90/p99, TPOT and ITL mean, end-to-end latency p50/p90/p99.

Usage:
    summarize-results.py <dir> [--json]

Exit codes: 0 success, 1 no report found or unreadable, 2 usage error.
Requires python3 and PyYAML. Read-only.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.stderr.write("error: PyYAML is required (pip install pyyaml)\n")
    sys.exit(1)

REPORT_RE = re.compile(r"^benchmark_report.*\.ya?ml$")


def find_reports(root: Path) -> list[Path]:
    if root.is_file():
        return [root]
    return sorted(p for p in root.rglob("*") if p.is_file() and REPORT_RE.match(p.name))


def get(d, path: str, default=None):
    node = d
    for key in path.split("."):
        if not isinstance(node, dict) or key not in node:
            return default
        node = node[key]
    return node


def to_ms(value, units):
    if value is None:
        return None
    if units in ("s", "s/token"):
        return value * 1000.0
    return value  # already ms or unknown; reported as-is


def summarize_report(path: Path) -> dict:
    data = yaml.safe_load(path.read_text())
    if not isinstance(data, dict):
        raise ValueError(f"{path}: not a mapping")
    load = get(data, "scenario.load.standardized", {}) or {}
    agg = get(data, "results.request_performance.aggregate", {}) or {}
    lat = agg.get("latency", {}) or {}
    thr = agg.get("throughput", {}) or {}
    req = agg.get("requests", {}) or {}

    def stat(block: dict, name: str, field: str):
        node = block.get(name) or {}
        return node.get(field)

    def lat_ms(name: str, field: str):
        node = lat.get(name) or {}
        return to_ms(node.get(field), node.get("units"))

    experiment = path.parent.name
    return {
        "file": str(path),
        "experiment": experiment,
        "stage": load.get("stage"),
        "tool": load.get("tool"),
        "rate_qps": load.get("rate_qps"),
        "concurrency": load.get("concurrency"),
        "requests_total": req.get("total"),
        "requests_failed": req.get("failures"),
        "request_rate_mean": stat(thr, "request_rate", "mean"),
        "output_token_rate_mean": stat(thr, "output_token_rate", "mean"),
        "total_token_rate_mean": stat(thr, "total_token_rate", "mean"),
        "ttft_ms_p50": lat_ms("time_to_first_token", "p50"),
        "ttft_ms_p90": lat_ms("time_to_first_token", "p90"),
        "ttft_ms_p99": lat_ms("time_to_first_token", "p99"),
        "tpot_ms_mean": lat_ms("time_per_output_token", "mean"),
        "itl_ms_mean": lat_ms("inter_token_latency", "mean"),
        "e2e_ms_p50": lat_ms("request_latency", "p50"),
        "e2e_ms_p90": lat_ms("request_latency", "p90"),
        "e2e_ms_p99": lat_ms("request_latency", "p99"),
        "run_description": get(data, "run.description"),
        "model": _model_name(data),
    }


def _model_name(data: dict):
    """Model name from the first stack component that declares one.

    ``standardized.model`` is a mapping (``name``, ...) in schema v0.2; older
    reports may carry a plain string."""
    for component in get(data, "scenario.stack", []) or []:
        if not isinstance(component, dict):
            continue
        model = get(component, "standardized.model")
        if isinstance(model, dict) and model.get("name"):
            return str(model["name"])
        if isinstance(model, str) and model:
            return model
    return None


def fmt(value, digits=1):
    if value is None:
        return "-"
    if isinstance(value, float):
        return f"{value:.{digits}f}"
    return str(value)


def print_table(rows: list[dict]) -> None:
    header = [
        ("experiment", 34), ("stage", 5), ("load", 14), ("reqs", 6), ("fail", 4),
        ("req/s", 7), ("out tok/s", 9), ("TTFT p50", 8), ("TTFT p90", 8), ("TTFT p99", 8),
        ("TPOT", 7), ("ITL", 7), ("E2E p50", 8), ("E2E p90", 8), ("E2E p99", 8),
    ]
    print("latencies in ms; rates are per second")
    print(" ".join(f"{name:<{w}}" for name, w in header))
    for r in rows:
        load = (
            f"{r['rate_qps']} qps" if r.get("rate_qps") is not None
            else (f"conc {r['concurrency']}" if r.get("concurrency") is not None else "-")
        )
        values = [
            (r["experiment"][:34], 34), (fmt(r["stage"]), 5), (load, 14),
            (fmt(r["requests_total"]), 6), (fmt(r["requests_failed"]), 4),
            (fmt(r["request_rate_mean"], 2), 7), (fmt(r["output_token_rate_mean"]), 9),
            (fmt(r["ttft_ms_p50"]), 8), (fmt(r["ttft_ms_p90"]), 8), (fmt(r["ttft_ms_p99"]), 8),
            (fmt(r["tpot_ms_mean"]), 7), (fmt(r["itl_ms_mean"]), 7),
            (fmt(r["e2e_ms_p50"]), 8), (fmt(r["e2e_ms_p90"]), 8), (fmt(r["e2e_ms_p99"]), 8),
        ]
        print(" ".join(f"{v:<{w}}" for v, w in values))
    models = sorted({r["model"] for r in rows if r.get("model")})
    if models:
        print(f"model(s): {', '.join(models)}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Summarize llmdbenchmark benchmark reports per stage.")
    parser.add_argument("target", help="run directory, results directory, experiment directory, or a report file")
    parser.add_argument("--json", action="store_true", help="emit JSON instead of a table")
    args = parser.parse_args(argv)

    root = Path(args.target)
    if not root.exists():
        sys.stderr.write(f"error: {root} does not exist\n")
        return 1
    reports = find_reports(root)
    if not reports:
        sys.stderr.write(
            f"error: no benchmark_report*.yaml under {root}. The harness-agnostic report is written "
            "by every harness except lm-eval; check results/<experiment-id>_<i>/ or re-collect with "
            "`llmdbenchmark ... run --skip`.\n"
        )
        return 1
    rows = []
    for p in reports:
        try:
            rows.append(summarize_report(p))
        except Exception as exc:  # noqa: BLE001 - report the file, continue
            sys.stderr.write(f"warning: skipping {p}: {exc}\n")
    if not rows:
        return 1
    rows.sort(key=lambda r: (r["experiment"], r["stage"] if r["stage"] is not None else -1))
    if args.json:
        json.dump(rows, sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        print_table(rows)
    return 0


if __name__ == "__main__":
    sys.exit(main())
