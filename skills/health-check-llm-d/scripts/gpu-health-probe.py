#!/usr/bin/env python3
"""GPU health probe for llm-d inference pods.

Sends an identical set of requests to each pod's inference endpoint, measures
time-to-first-token (TTFT) and time-per-output-token (TPOT), and flags pods
whose latency is a significant outlier among their peers in the same --group.

Note on TP/DP deployments: with Tensor Parallelism (TP) or internal Data
Parallelism (DP), each pod uses multiple GPUs working together. This check
detects pod-level (TP/DP group) performance anomalies, not individual GPU
anomalies. A flagged pod indicates the pod's GPU group is underperforming
relative to peer pods.

Key design points for a fair comparison:
  * The SAME prompt set is sent to every pod (drawn once, reused) so that
    prompt-length variance does not masquerade as a performance difference.
  * One warmup request per pod is sent and discarded (avoids cold-start bias).
  * Pods are compared only against others in their own --group (prefill and
    decode pods in a PD-disaggregated stack have different baselines).

Usage:
    python3 gpu-health-probe.py \
        --endpoints http://localhost:18001 http://localhost:18002 \
        --pod-names decode-0 decode-1 \
        --groups decode decode \
        --model meta-llama/Llama-3.1-8B-Instruct \
        --requests 8 --max-tokens 50 --threshold 2.0 --api chat

Exit codes:
    0 - all pods healthy
    1 - one or more pods SUSPICIOUS or UNHEALTHY (vs peers)
    2 - fatal error (no successful responses at all, bad arguments)
"""
from __future__ import print_function

import argparse
import json
import random
import statistics
import sys
import time
import urllib.error
import urllib.request
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Dict, List, Optional, Tuple

PROMPTS = [
    "Explain the concept of gradient descent in machine learning.",
    "What are the key differences between Python and JavaScript?",
    "Describe the process of photosynthesis in plants.",
    "Write a brief history of the internet.",
    "What is quantum computing and how does it work?",
    "Explain the water cycle in nature.",
    "What are the main programming paradigms?",
    "Describe how TCP/IP networking works.",
    "What is the difference between supervised and unsupervised learning?",
    "Explain the concept of recursion in programming.",
    "What causes seasons on Earth?",
    "How does a compiler differ from an interpreter?",
]

MAX_CONCURRENT_PER_POD = 4

# Relative floor: only flag a pod if the absolute gap also exceeds this
# fraction of the group median. Scales automatically with model speed.
# Example: TTFT median=0.5s → floor=0.075s; TTFT median=0.1s → floor=0.015s.
FLOOR_FRACTION = 0.15


def build_request_plan(n_requests: int, seed: int = 1234) -> List[str]:
    """Draw the prompt list ONCE so every pod receives the same requests.

    Uses a fixed seed so prompts are varied but identical across pods and
    reproducible across runs — what makes the comparison fair.
    """
    rng = random.Random(seed)
    return [rng.choice(PROMPTS) for _ in range(n_requests)]


def send_request(
    endpoint: str, model: str, prompt: str, max_tokens: int, api: str,
    timeout: int = 120,
) -> Tuple[Optional[float], Optional[float], int, Optional[str]]:
    """Send one streaming request.

    Returns (ttft_s, total_s, n_content_chunks, error_or_None).
    """
    if api == "completions":
        url = "{}/v1/completions".format(endpoint)
        payload = {"model": model, "prompt": prompt,
                   "max_tokens": max_tokens, "stream": True}
    else:
        url = "{}/v1/chat/completions".format(endpoint)
        payload = {"model": model,
                   "messages": [{"role": "user", "content": prompt}],
                   "max_tokens": max_tokens, "stream": True}

    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    t0 = time.perf_counter()
    ttft = None  # type: Optional[float]
    n_chunks = 0
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            for raw in resp:
                line = raw.strip()
                if not line or not line.startswith(b"data:"):
                    continue
                chunk = line[5:].strip()
                if chunk == b"[DONE]":
                    break
                try:
                    obj = json.loads(chunk)
                    choice = obj["choices"][0]
                    # chat: delta.content ; completions: text
                    content = choice.get("delta", {}).get("content")
                    if content is None:
                        content = choice.get("text", "")
                    if content:
                        n_chunks += 1
                        if ttft is None:
                            ttft = time.perf_counter() - t0
                except (KeyError, IndexError, ValueError):
                    pass
    except urllib.error.HTTPError as e:
        body = ""
        try:
            body = e.read().decode("utf-8", "replace")[:200]
        except Exception:
            pass
        return None, None, 0, "HTTP {}: {}".format(e.code, body or e.reason)
    except urllib.error.URLError as e:
        return None, None, 0, "URLError: {}".format(e.reason)
    except Exception as e:
        return None, None, 0, str(e)

    total = time.perf_counter() - t0
    if ttft is None:
        return None, None, 0, "no token content received in response"
    return ttft, total, n_chunks, None


def probe_pod(
    endpoint: str, model: str, prompts: List[str], max_tokens: int, api: str,
    request_timeout: int = 15,
) -> Dict:
    """Warm up once (discarded), then send the shared prompt list concurrently."""
    # Warmup: absorb cold-start cost. Errors here are ignored.
    send_request(endpoint, model, prompts[0], max_tokens, api, timeout=request_timeout)

    ttfts = []   # type: List[float]
    tpots = []   # type: List[float]
    errors = []  # type: List[str]
    concurrency = max(1, min(len(prompts), MAX_CONCURRENT_PER_POD))
    with ThreadPoolExecutor(max_workers=concurrency) as ex:
        futures = [
            ex.submit(send_request, endpoint, model, p, max_tokens, api, request_timeout)
            for p in prompts
        ]
        for f in as_completed(futures):
            ttft, total, n_chunks, err = f.result()
            if err:
                errors.append(err)
                continue
            ttfts.append(ttft)
            if n_chunks > 1 and total is not None:
                tpots.append((total - ttft) / (n_chunks - 1))
    return {"ttfts": ttfts, "tpots": tpots, "errors": errors}


def mean_or_none(xs: List[float]) -> Optional[float]:
    return statistics.mean(xs) if xs else None


def median_or_none(xs: List[float]) -> Optional[float]:
    return statistics.median(xs) if xs else None


def fmt_s(v: Optional[float]) -> str:
    return "{:.3f}s".format(v) if v is not None else "N/A"


def evaluate_group(
    pods: List[str], results: Dict[str, Dict], threshold: float,
    floor_fraction: float,
) -> Tuple[Dict[str, List[str]], Optional[float], Optional[float], bool]:
    """Return (reasons_by_pod, median_ttft, median_tpot, weak_flag) for a group.

    reasons_by_pod maps pod -> list of peer-outlier reason strings (empty = ok).
    Pods with no successful responses are omitted here (handled as UNHEALTHY
    by the caller).

    The absolute floor scales with the group median so it adapts to fast and
    slow models alike.
    """
    all_ttfts = [t for p in pods for t in results[p]["ttfts"]]
    all_tpots = [t for p in pods for t in results[p]["tpots"]]
    med_ttft = statistics.median(all_ttfts) if all_ttfts else None
    med_tpot = statistics.median(all_tpots) if all_tpots else None

    floor_ttft = floor_fraction * med_ttft if med_ttft else 0.0
    floor_tpot = floor_fraction * med_tpot if med_tpot else 0.0

    # Outlier detection needs at least 3 responsive pods to be meaningful.
    responsive = [p for p in pods if results[p]["ttfts"]]
    weak = len(responsive) < 3

    reasons_by_pod = {}  # type: Dict[str, List[str]]
    for p in pods:
        r = results[p]
        if not r["ttfts"]:
            continue
        reasons = []  # type: List[str]
        m_ttft = statistics.mean(r["ttfts"])
        if (med_ttft and m_ttft > threshold * med_ttft
                and (m_ttft - med_ttft) > floor_ttft):
            reasons.append("TTFT {:.1f}x vs peers".format(m_ttft / med_ttft))
        if r["tpots"] and med_tpot:
            m_tpot = statistics.mean(r["tpots"])
            if (m_tpot > threshold * med_tpot
                    and (m_tpot - med_tpot) > floor_tpot):
                reasons.append("TPOT {:.1f}x vs peers".format(m_tpot / med_tpot))
        reasons_by_pod[p] = reasons
    return reasons_by_pod, med_ttft, med_tpot, weak


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Pod health probe via TTFT/TPOT peer comparison across llm-d pods"
    )
    parser.add_argument("--endpoints", nargs="+", required=True,
                        help="Local endpoint URLs, one per pod (order matters)")
    parser.add_argument("--pod-names", nargs="+", required=True,
                        help="Pod names, same order as --endpoints")
    parser.add_argument("--groups", nargs="+", default=None,
                        help="Group label per pod. Pods are compared only within "
                             "their group. Default: all pods in one group.")
    parser.add_argument("--model", required=True, help="Model ID as served by vLLM")
    parser.add_argument("--requests", type=int, default=8,
                        help="Requests per pod (default: 8)")
    parser.add_argument("--max-tokens", type=int, default=50,
                        help="Max tokens per request (default: 50)")
    parser.add_argument("--threshold", type=float, default=2.0,
                        help="Peer outlier: flag if mean latency > threshold x "
                             "group median (default: 2.0)")
    parser.add_argument("--floor-fraction", type=float, default=FLOOR_FRACTION,
                        help="Relative floor: only flag when the absolute gap "
                             "also exceeds this fraction of the group median "
                             "(default: {})".format(FLOOR_FRACTION))
    parser.add_argument("--api", choices=["chat", "completions"], default="chat",
                        help="Endpoint type; 'completions' for base models "
                             "without a chat template (default: chat)")
    parser.add_argument("--request-timeout", type=int, default=15,
                        help="Per-request HTTP timeout in seconds (default 15). "
                             "Dead port-forwards hang for this long before failing.")
    parser.add_argument("--no-confirm-tpot", dest="confirm_tpot",
                        action="store_false", default=True,
                        help="Skip TPOT re-probe confirmation step (faster, "
                             "but may report transient memory-pressure spikes "
                             "as SUSPICIOUS).")
    args = parser.parse_args()

    if len(args.endpoints) != len(args.pod_names):
        print("ERROR: --endpoints and --pod-names must have the same length.")
        return 2
    if args.groups and len(args.groups) != len(args.pod_names):
        print("ERROR: --groups must have one entry per pod.")
        return 2
    if args.requests < 1:
        print("ERROR: --requests must be >= 1.")
        return 2

    groups = args.groups or ["default"] * len(args.pod_names)
    endpoint_by_pod = {pod: ep for pod, ep in zip(args.pod_names, args.endpoints)}
    prompts = build_request_plan(args.requests)

    print("\nPod health check")
    print("  model     : {}".format(args.model))
    print("  api       : /v1/{}".format(
        "chat/completions" if args.api == "chat" else "completions"))
    print("  requests  : {} per pod ({} concurrent), 1 warmup discarded".format(
        args.requests, MAX_CONCURRENT_PER_POD))
    print("  max_tokens: {}".format(args.max_tokens))
    print("  peers     : flag > {}x group median, floor={}% of median".format(
        args.threshold, int(args.floor_fraction * 100)))
    print("  tpot check: {}".format(
        "re-probe to confirm (transient spikes cleared)"
        if args.confirm_tpot else "single-pass (--no-confirm-tpot)"))
    print("")

    results = OrderedDict()  # type: Dict[str, Dict]
    group_by_pod = {}        # type: Dict[str, str]
    for pod, endpoint, grp in zip(args.pod_names, args.endpoints, groups):
        group_by_pod[pod] = grp
        sys.stdout.write("  Probing {:40s} ... ".format(pod))
        sys.stdout.flush()
        r = probe_pod(endpoint, args.model, prompts, args.max_tokens, args.api,
                      args.request_timeout)
        results[pod] = r
        if r["ttfts"]:
            sys.stdout.write("ok  ({}/{} ok, TTFT={}, TPOT={})\n".format(
                len(r["ttfts"]), args.requests,
                fmt_s(mean_or_none(r["ttfts"])), fmt_s(mean_or_none(r["tpots"]))))
        else:
            sys.stdout.write("FAILED ({} errors; first: {})\n".format(
                len(r["errors"]), r["errors"][0] if r["errors"] else "unknown"))
        sys.stdout.flush()

    if not any(r["ttfts"] for r in results.values()):
        print("\nERROR: No successful responses from any pod. Cannot assess health.")
        print("       Check port-forwards, the model name, and --api "
              "(base models need 'completions').")
        return 2

    # Group pods preserving first-seen order.
    group_order = []  # type: List[str]
    group_members = OrderedDict()  # type: Dict[str, List[str]]
    for pod, g in zip(args.pod_names, groups):
        if g not in group_members:
            group_members[g] = []
            group_order.append(g)
        group_members[g].append(pod)

    peer_reasons = {}   # type: Dict[str, List[str]]
    group_medians = {}  # type: Dict[str, Tuple[Optional[float], Optional[float], bool]]
    for g in group_order:
        members = group_members[g]
        pr, med_ttft, med_tpot, weak = evaluate_group(
            members, results, args.threshold, args.floor_fraction)
        group_medians[g] = (med_ttft, med_tpot, weak)
        peer_reasons.update(pr)

    # TPOT re-probe: for any pod flagged on TPOT (memory pressure is transient),
    # send another batch and only confirm if TPOT is still elevated.
    # TTFT flags (compute) are reported immediately without re-probe.
    transient_notes = []  # type: List[str]
    if args.confirm_tpot:
        tpot_flagged = [
            pod for pod in args.pod_names
            if results[pod]["ttfts"] and any(
                r.startswith("TPOT") for r in peer_reasons.get(pod, [])
            )
        ]
        if tpot_flagged:
            n_reprobe = max(8, args.requests // 2)
            re_prompts = build_request_plan(n_reprobe, seed=5678)
            print("\nRe-probing {} TPOT-suspicious pod(s) ({} requests each)...".format(
                len(tpot_flagged), n_reprobe))
            for pod in tpot_flagged:
                sys.stdout.write("  Re-probing {:40s} ... ".format(pod))
                sys.stdout.flush()
                re_r = probe_pod(endpoint_by_pod[pod], args.model, re_prompts,
                                 args.max_tokens, args.api, args.request_timeout)
                re_tpot = median_or_none(re_r["tpots"])
                _, med_tpot, _ = group_medians[group_by_pod[pod]]
                if re_tpot and med_tpot and re_tpot > args.threshold * med_tpot:
                    peer_reasons[pod] = [
                        r + " (confirmed)" if r.startswith("TPOT") else r
                        for r in peer_reasons.get(pod, [])
                    ]
                    sys.stdout.write("still slow — TPOT={} (confirmed)\n".format(
                        fmt_s(re_tpot)))
                else:
                    peer_reasons[pod] = [
                        r for r in peer_reasons.get(pod, [])
                        if not r.startswith("TPOT")
                    ]
                    transient_notes.append(
                        "  {} TPOT spike was transient (re-probe TPOT={})".format(
                            pod, fmt_s(re_tpot)))
                    sys.stdout.write("cleared — TPOT={} (transient, not flagged)\n".format(
                        fmt_s(re_tpot)))
                sys.stdout.flush()

    # Final per-pod status.
    status_by_pod = {}  # type: Dict[str, str]
    any_issue = False
    for pod in args.pod_names:
        if not results[pod]["ttfts"]:
            status_by_pod[pod] = "UNHEALTHY"
            any_issue = True
            continue
        reasons = peer_reasons.get(pod, [])
        if reasons:
            status_by_pod[pod] = "SUSPICIOUS (" + "; ".join(reasons) + ")"
            any_issue = True
        else:
            status_by_pod[pod] = "HEALTHY"

    # Report table.
    any_weak = False
    print("")
    print("=" * 84)
    print("  {:<34} {:>9} {:>9}  {}".format("Pod", "TTFT", "TPOT", "Status"))
    for g in group_order:
        med_ttft, med_tpot, weak = group_medians[g]
        any_weak = any_weak or weak
        label = g if g != "default" else "all pods"
        print("-" * 84)
        print("  group '{}'  (median TTFT={}, TPOT={}){}".format(
            label, fmt_s(med_ttft), fmt_s(med_tpot),
            "  [<3 pods: peer detection weak]" if weak else ""))
        for p in group_members[g]:
            r = results[p]
            print("  {:<34} {:>9} {:>9}  [ {} ]".format(
                p, fmt_s(mean_or_none(r["ttfts"])),
                fmt_s(mean_or_none(r["tpots"])), status_by_pod[p]))
    print("=" * 84)

    if transient_notes:
        print("\nTransient TPOT spikes (cleared on re-probe — recorded as HEALTHY):")
        for note in transient_notes:
            print(note)

    if any_issue:
        print("\nOne or more pods flagged. Suggested next steps:")
        print("  1. Check GPU/CUDA errors in flagged pod logs:")
        print('     kubectl logs -n $NAMESPACE <pod> | grep -iE "cuda|gpu|error|OOM|exception"')
        print("  2. Check node GPU allocation:")
        print("     kubectl describe node <node> | grep -A10 'Allocated resources'")
    else:
        print("\nAll {} pod(s) are HEALTHY.".format(len(results)))
    if any_weak:
        print("\nNote: a group had fewer than 3 responsive pods, so peer-based "
              "outlier detection is unreliable. Results should be treated as "
              "indicative only.")

    return 1 if any_issue else 0


if __name__ == "__main__":
    sys.exit(main())
