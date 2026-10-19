# Why the hot/warm/cold mix varies

## The mix is stochastic

Each iteration is classified after the fact:

- **Hot** — the instance shows a sleep -> wake history (woken from sleep).
- **Warm** — a launcher existed on the requester's node before this iteration
  (launcher creation predates the requester), so it forks the instance.
- **Cold-with-launcher** — no reusable launcher on the node, so one is created on
  demand for this request, then it forks the instance.

You cannot guarantee a particular count of each up front. Plan for a two-round
protocol: run once, inspect the mix, then decide whether a second round should
favor more cold or more hot/warm samples.

## What drives the count

The controller never deletes launcher pods on scale-to-0 — it only sleeps the
instance and unbinds; the launcher lingers. Only the launcher-populator deletes
unbound launchers, down to its configured count. So:

- Iteration 1 usually finds no launcher -> creates one on demand -> **cold**. It
  then lingers.
- Later iterations are a race: if the lingering launcher survives to the next
  requester bind -> **hot/warm**; if the populator deleted it first, or the
  requester lands on a different node, or an eviction removed the sleeping
  instance -> **cold** again.

So the cold count depends on populator-deletion-vs-next-bind timing, node
placement drift (launchers are node-pinned; pinning is off by default, so
requesters can scatter), mid-run eviction, and — importantly — **leftover
launchers from a prior run or model on shared nodes**. Incomplete teardown lowers
the cold count and corrupts the next model's mix, which is a second reason
teardown between models is mandatory.

## Population on vs off

Two config postures (in llm-d-benchmark these are the `coldstart` vs `fmablog`
branches):

- **Population off** (`launcherPopulator.enabled: false`, launcher count low) —
  no pre-warmed launchers, so runs yield some cold-with-launcher samples.
- **Population on** — pre-warmed sleeping launchers, so scale-ups go hot/warm; no
  cold samples.

## Steering toward more cold samples

- Keep the launcher populator off / count low so unbound launchers get reaped.
- Do not run a hotstart warmup step (it pre-sleeps launchers -> hot).
- Add a dwell between iterations long enough for the populator to delete the
  unbound launcher before the next scale-up (the biggest single lever — without
  it the harness scales straight back up and the launcher usually survives).
- Optionally disable launcher node-pinning so requesters scatter and miss the
  lingering launcher.

## Observed context

The "few cold starts even with population off" behavior (as low as one cold
sample in a 10-iteration run) was observed with the **Qwen3-4B** model. The
mechanism is model-independent; the specific counts are not.

## Compile-cache fairness note

When `VLLM_CACHE_ROOT` points at a shared PVC, torch.compile / Inductor / Triton
artifacts are always-hit after the first prime. That means warm and cold samples
on a shared cache do not include a cold torch.compile — so a no-FMA baseline must
use the same cache policy or the comparison is apples-to-oranges. Record, per
iteration, the launcher summary's `Compile` vs `Load from Cache` line so each
sample's cache state is auditable.
