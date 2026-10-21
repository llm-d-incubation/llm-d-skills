---
name: run-fma-benchmark
description: >-
  Use when running llm-d-benchmark's Fast Model Actuation (FMA) actuation-timing
  benchmark on an OpenShift/Kubernetes cluster — the standup -> run -> teardown
  loop with the nop harness that measures hot/warm/cold actuation latency. Covers
  the model-agnostic recipe (any open vLLM model, one model or a list), the
  gotchas that produce silent zero-iteration runs, and the FMA-specific --set
  knobs. Not for throughput benchmarks (vllm-benchmark / guidellm / inference-perf).
license: Apache-2.0
metadata:
  domain: llm-d-benchmark
  harness: nop
---

# Run the FMA actuation-timing benchmark

## What this measures

The Fast Model Actuation (FMA) benchmark measures how long it takes to bring an
inference instance to readiness — *actuation latency* — not tokens/sec. It uses
the `nop` harness (distinct from the throughput harnesses `vllm-benchmark`,
`guidellm`, `inference-perf`, `inferencemax`). Each iteration is classified into
one of three actuation paths and timed:

| Path | Metric field | Typical span | What happens |
|------|--------------|--------------|--------------|
| Hot | `t_wake` | sub-second | A sleeping instance is woken (weights DRAM -> GPU). |
| Warm | `t_instance_create` | ~50-110s | The launcher forks a new instance, inheriting preloaded vLLM modules. |
| Cold-with-launcher | `t_cold_launcher` | ~70-166s | No reusable launcher on the node, so one is created on demand, then it forks the instance. |

Each iteration also records `actuation_condition` (the classification) and
`timing_source` (want `dpc` — the tightest, controller-derived anchor). The mix
of hot/warm/cold per run is stochastic; see `references/actuation-mix.md`.

## Before you start — ask the user

This skill is model-agnostic. FMA runs any vLLM-compatible open model. **Do not
assume a model.** Ask the user:

1. **Confirm the target cluster + namespace (default to the current context).**
   The user owns `oc login`; this skill does not log in. **Detect and surface the
   current context, and use it by default** — do not ask the user to supply a
   namespace from scratch. Run `kubectl config current-context` and derive the
   namespace (`kubectl config view --minify -o jsonpath='{..namespace}'`, falling
   back to asking only if none is set), then tell the user plainly: *"This will
   run against context `<ctx>`, namespace `<ns>`."* Proceed on that unless the
   user names a different namespace/context. FMA uses shared cluster GPUs, so this
   is a one-line confirmation, not a silent assumption.
   - If the user prefers their current context not move, they can pin a kubeconfig
     per command instead — pass `--kubeconfig <path>` (or `KUBECONFIG=<path>`) on
     the `kubectl` checks and point the run at that namespace with `-p <ns>`; the
     `llmdbenchmark` steps already take `-p $NS` explicitly.
2. **Which open model(s)?** Ideally with the HuggingFace ID (e.g. `Qwen/Qwen3-8B`).
   Prefer ungated models — a gated model (e.g. `meta-llama/Llama-3.1-8B-Instruct`)
   needs both an `HF_TOKEN` and per-model access approval on HuggingFace, which
   blocks first-time runs. `Qwen/Qwen3-8B` is a verified ungated substitute.
3. **One model, or a list?** The workflow below runs standup -> run -> teardown
   once per model. For a list, repeat the whole loop per model with a mandatory
   teardown between each (shared GPUs, and leftover launchers corrupt the next
   model's hot/warm/cold mix).
This skill uses `--spec cicd/ocp` with `--methods fma` throughout — the form
verified across the multi-size runs with the current `llmdbenchmark` CLI. In the
spec name, `cicd` is the CI/CD scenario family and `ocp` is the OpenShift
platform scenario within it (siblings target other platforms, e.g. `cks`, `gke`,
`kind`); the same OpenShift scenario is what the nightly workflows consume.
`--methods fma` selects the FMA deploy path within that spec.

## Prerequisites

- **CLI available.** Either an already-active virtualenv that has the
  llm-d-benchmark CLI installed (verify with `llmdbenchmark --version`), or a
  fresh venv with `./install.sh` run in the repo. If a venv is already active and
  `llmdbenchmark` resolves, you do not need to reinstall.
  - **Python version matters.** Current `main` declares `requires-python >=3.14`
    and uses 3.14-only syntax (PEP 758 unparenthesized `except X, Y:`), so the CLI
    **will not even import on Python < 3.14** (`SyntaxError` at `cli.py`). Use a
    **Python 3.14** venv for current `main` (e.g. `uv python install 3.14` +
    `uv venv --python 3.14 <path>`; note `uv` only serves a *final* 3.14.x if its
    index is fresh — `pip install -U uv` if it offers only an rc). Older checkouts
    (≤ ~Sept 2026) still run on 3.12. Also install the separate `planner` package
    the CLI imports: `pip install git+https://github.com/llm-d-incubation/llm-d-planner.git@<ver>`
    (install.sh does this for you).
- **Cluster access.** The user runs `oc login` / populates the kubeconfig; this
  skill does not log in. Verify with `kubectl config current-context` and
  `kubectl get ns <namespace>`.
- **Tooling.** helm >= v3.19.0 (Helm 3.19.x is fine — the guide's "v4.2.0" is a
  stale note), helmfile >= v1.5.0. **bash:** the FMA installer (`install-fma.sh`,
  fetched at standup) historically word-split unquoted here-strings under macOS's
  **bash 3.2** (fixed for the YAML path in FMA v0.7.0 / #757, remaining JSON
  here-strings cleaned in #804). Prefer FMA **>= v0.7.0** (`--set fma.chart.version`)
  to avoid the bash-3.2 standup failure; v0.6.5 fails at `fma_deploy` on bash 3.2.
- **GPU node label.** GPU nodes must carry `nvidia.com/gpu.present=true` (the
  `LauncherPopulationPolicy` node selector hardcodes it). The NVIDIA GPU Operator
  sets this on OpenShift; on vanilla k8s / ACK / GKE / EKS you may need to label
  nodes manually.

## Workflow

Set once. `NS` defaults to the current context's namespace (surfaced and
confirmed per "Before you start" above); only override it if the user named a
different one:

```
NS=$(kubectl config view --minify -o jsonpath='{..namespace}')   # default: current context's ns
WS=~/data/fma         # a durable workspace dir (results land under a timestamped subdir)
```

### Step 1 — Choose the model config

Swap the model as a **trio + shortName**, and pass the SAME `--set` flags on BOTH
standup and run (see `references/model-swap.md` for why omitting them on run
silently falls back to a 4B lookup and a fake exit-0 success):

```
--set model.name=<HuggingFaceID> \
--set model.shortName=<short-slug> \
--set model.path=models/<HuggingFaceID> \
--set model.huggingfaceId=<HuggingFaceID>
```

`model.huggingfaceId` is the download source (becomes `HF_MODEL_ID` for the
download job) and is always required. `model.name` must stay the repo ID (it
feeds the derived Helm release name; a path there mangles the release name).

**Always set a KV-cache cap on `cicd/ocp` — it has none by default.** The base
`cicd/ocp` scenario renders `--enable-sleep-mode --gpu-memory-utilization 0.95
--max-model-len 40960` with **no** `--kv-cache-memory`, which deterministically
OOMs at vLLM sampler warmup on an 80GB card (even for a 4B model) — the launcher
child crashes, the server port never binds, and the run ends with 0 iterations
(see `references/kv-cache-oom.md`). The sibling FMA scenarios (`ocp-keda-fma-*`)
avoid this by shipping a cap. Pass one from the start, on BOTH standup and run:

```
--set model.maxModelLen=16000 \
--set fma.launcher.kvCacheMemory=11259300148   # ~10.49 GiB, the sibling-scenario default
```

`11259300148` at `maxModelLen=16000` is a known-good conservative default for a
single 80GB GPU; see `references/kv-cache-oom.md` for per-model tuning.

For models that do not fit on one GPU (roughly >= 32B on an 80GB card), add the
big-model knobs (`fma.launcher.tensorParallelSize`, `fma.requester.limitsGPU`,
and a KV-cache cap) — see `references/big-models.md`.

### Step 2 — Dry-run render (no cluster changes)

Confirm the FMA path and the model override before going live. The `-n` /
`--dry-run` flag is global (before the subcommand):

```
llmdbenchmark --spec cicd/ocp -n standup \
  -p $NS --gateway-class none --methods fma \
  --set model.name=<M> --set model.shortName=<short> \
  --set model.path=models/<M> --set model.huggingfaceId=<M> \
  --base-dir . --ws $WS
```

In the rendered plan, confirm: the FMA deploy path is selected (`deploy.methods`
includes `fma`), the `InferenceServerConfig` / `LauncherConfig` /
`LauncherPopulationPolicy` render, and the override log line reads
`override: model.name '<old>' -> '<new>'` — where `<old>` is a real value, NOT
`<unset>`. An `<unset>` old value means the key is wrong (see
`references/model-swap.md`).

### Step 3 — Standup

```
llmdbenchmark --spec cicd/ocp standup \
  -p $NS --gateway-class none --methods fma \
  --set model.name=<M> --set model.shortName=<short> \
  --set model.path=models/<M> --set model.huggingfaceId=<M> \
  --set model.maxModelLen=16000 --set fma.launcher.kvCacheMemory=11259300148 \
  --base-dir . --ws $WS
```

(The `maxModelLen` + `kvCacheMemory` flags are the KV-cache cap from Step 1 —
required on `cicd/ocp` or the launcher OOMs. Tune per `references/kv-cache-oom.md`.)

The `--release` flag is not required for standup — the namespace prefix
(`-p $NS`) is enough. (Some older runbooks pass `--release <name>`; on the FMA
path it is cosmetic because the release name is derived from the model.)

**First standup on a cold node may fail at `harness_namespace` (120s timeout).**
The `harness_namespace` step waits only 120s for the `access-to-harness-data-*`
pod, but that pod cold-pulls the ~7GB `llm-d-benchmark:nightly` image, which can
take ~5 minutes on a node that has not cached it. Standup then fails with
`Data access pod not ready: Timed out after 120s`, even though the pod comes up
healthy moments later (orphaned). This is a cold-pull timing issue, not a real
failure: just **re-run standup** — the image is now cached on that node and the
step passes. (Same class as the launcher-image note below.)

**Wait for launcher readiness before running.** The launcher image is large
(~8GB) and can sit in `ContainerCreating` for ~19 minutes on first pull. The
`run` step does not gate on launcher readiness, so running early yields
`iterations: []` and all-zero metrics. Wait:

```
kubectl get pods -n $NS -l app.kubernetes.io/component=launcher -w
```

### Step 4 — Run (nop actuation harness)

```
llmdbenchmark --spec cicd/ocp run \
  -p $NS --methods fma --harness nop --workload nop.yaml \
  --set harness.executable=llm-d-benchmark.py \
  --set model.name=<M> --set model.shortName=<short> \
  --set model.path=models/<M> --set model.huggingfaceId=<M> \
  --set model.maxModelLen=16000 --set fma.launcher.kvCacheMemory=11259300148 \
  --base-dir . --ws $WS
```

Pass the SAME KV-cache cap (`maxModelLen` + `kvCacheMemory`) here as on standup —
the run derives the launcher config from its own model/KV flags.

`--set harness.executable=llm-d-benchmark.py` is required for the nop harness
when the scenario leaves `harness.executable` commented (it otherwise defaults to
a `.sh` entrypoint that never actuates). `run` takes no `--release`.

Watch for `step_09` logging `Collected N file(s) to <local dir>`. The authoritative
copy is local by the time teardown runs.

### Step 5 — Verify results exist, then parse

**On current FMA (v0.7.0+) a successful run PACKS results into an archive — there
is no loose `result.yaml` to `find`.** The run collects
`<WS>/<workspace-id>/results/nop-*_1/workspace.tar.zst`, and `result.yaml` lives
*inside* it. (`find $WS -name result.yaml` returns nothing on a clean run — that
is expected, not a failure.) Loose, uncompressed result files appear ONLY when a
run fails ("collecting results uncompressed"), so compressed-vs-loose is itself a
success/failure signal.

Confirm the archive exists, then extract and parse:

```
find $WS -name workspace.tar.zst            # the per-run results archive
tar --use-compress-program=unzstd -xf <WS>/<workspace-id>/results/nop-*_1/workspace.tar.zst -C /tmp/fma-result
```

Then parse `/tmp/fma-result/result.yaml` with the venv Python (system Python may
not have yaml). Per iteration, read
`extra_metrics[0].iterations[*].launcher_infos[0]` for `actuation_condition`,
`timing_source`, and whichever of `t_wake` / `t_instance_create` /
`t_cold_launcher` is set. Full parse snippet in `references/parse-results.md`.
Confirm `scenario.model.name` matches the model you intended (a 4B fallback shows
up here).

### Step 5b — Present the results (always end a run with this)

Do not leave the user with raw per-iteration dumps. **End every run by showing a
compact table + a one-paragraph synopsis** that says what the metrics mean and
what this run's numbers were, so a reader who has never seen FMA output can
interpret it. Report, per model:

- **Model**, total **iterations**, and the **hot / warm / cold mix** (counts).
- Per path that occurred: **count**, and **median** (+ min–max) of its timing
  field — `t_wake` (hot), `t_instance_create` (warm), `t_cold_launcher` (cold),
  in seconds.
- **`timing_source`**: confirm `dpc` for all (note if any fell back to a Kube
  anchor — those are looser and should be flagged, not silently averaged).

Then a plain-English synopsis: one line defining each path (hot = waking a
sleeping instance, sub-second; warm = launcher forks a new instance, ~tens of
seconds; cold = a launcher is created first, then forks), and what this run
showed. See `references/parse-results.md` for the table template + synopsis
wording and a worked example.

### Step 6 — Teardown (mandatory) + Helm uninstall

Shared GPUs — always tear down, even on failure.

```
llmdbenchmark --spec cicd/ocp teardown \
  -p $NS --gateway-class none --methods fma \
  --base-dir . --ws $WS
```

On older checkouts, teardown can leave the per-model Helm release `deployed`,
which makes the next same-model standup skip the controller deploy and hang. If
so, uninstall it explicitly — see `references/teardown-helm-leak.md`. Then verify
clean:

```
kubectl get pods -n $NS   # no launcher/requester/controller pods left
```

### Step 7 — Next model or done

For a model list, return to Step 1 with the next model. Do not start the next
model until Step 6 shows a clean namespace.

## Troubleshooting

| Symptom | Likely cause | Where |
|---------|--------------|-------|
| `iterations: []` / all-zero metrics | Ran before launcher pods Ready (large image pull) | Step 3 wait |
| Run "succeeds" but 0 iters, results show a different (smaller) model | Model `--set` omitted on run -> 4B fallback | `references/model-swap.md` |
| Launcher child OOMs at sampler warmup / `EngineCore failed to start` | No KV-cache cap on `cicd/ocp`; sleep-mode + warmup exceed GPU headroom | Step 1 KV cap; `references/kv-cache-oom.md` |
| Standup fails `Data access pod not ready: Timed out after 120s` | Harness data-access pod cold-pulling the ~7GB nightly image > 120s; pod comes up healthy after | Step 3 note — just re-run standup |
| Run aborts, 0 iters, `ValidationError ... read_namespaced_pod_log` / `pretty` | `pydantic>=2.14` harness bug (bool `pretty=False`) — **fixed in #2078 (merged)**. If you still hit it, your harness image predates the fix: pull/rebuild the latest `llm-d-benchmark:nightly` (or build a branch-tagged image). | llm-d/llm-d-benchmark#2078 (fixed) |
| Instance never `is_sleeping` / requester stuck `stopped` | Multiple root causes share this signature | `references/stopped-triage.md` |
| Next same-model standup hangs "no pods found" ~900s | Teardown left the Helm release `deployed` | `references/teardown-helm-leak.md` |
| Launchers never schedule | GPU nodes missing `nvidia.com/gpu.present=true` | Prerequisites |

## Execution rules

- Never run a live cluster step without the user's go-ahead. The user owns
  `oc login`.
- Surface the current context + namespace and confirm it with the user before
  standup; default to it, override only if the user names another. Shared GPUs.
- Teardown is mandatory between models and after the last model — shared GPUs.
- Always dry-run render (Step 2) before going live; confirm the model override is
  not `<unset>`.
- Pass the model `--set` flags on BOTH standup and run.
- Verify `result.yaml` exists before reporting success.

## What not to do

- Do not assume a model — ask the user.
- Do not omit the model `--set` on the run command.
- Do not pass a filesystem path as `model.name` (it mangles the release name;
  use `fma.launcher.loadModelFromLocalDir` instead — `references/big-models.md`).
- Do not skip teardown, even when a run fails.

## Reference files

- `references/model-swap.md` — the `model.*` vs `common.model.*` gotcha, both-commands rule.
- `references/kv-cache-oom.md` — `fma.launcher.kvCacheMemory` and how to read vLLM's suggested value.
- `references/big-models.md` — tensor parallelism, `/dev/shm`, `loadModelFromLocalDir`, KV cap.
- `references/stopped-triage.md` — the `stopped` / never-`is_sleeping` signature and its root causes.
- `references/teardown-helm-leak.md` — the leftover-release hang and the uninstall fix.
- `references/parse-results.md` — result.yaml parse path and snippet.
- `references/actuation-mix.md` — why the hot/warm/cold mix varies and how to steer it.
