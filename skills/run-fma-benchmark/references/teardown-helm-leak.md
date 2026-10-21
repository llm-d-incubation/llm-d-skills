# Teardown leaves the per-model Helm release `deployed`

## The gotcha (checkouts before the teardown-cleanup fix)

On checkouts predating the teardown-cleanup fix (see Current status),
`llmdbenchmark teardown` deletes the FMA custom resources and pods but leaves the
per-model Helm release in state `deployed`. The next standup for the same model
then sees the release as already installed, skips the controller deploy, and
hangs waiting ~900s for controller pods that never come ("no pods found").

## Confirm

```
helm list -n $NS
```

A lingering entry ending in `-fma-dp` (the per-model FMA release) after teardown
is the leak.

## Fix: uninstall it explicitly

```
helm list -n $NS -q | grep fma-dp | xargs -r -n1 helm uninstall -n $NS
```

Then verify clean:

```
helm list -n $NS          # no fma-dp release
kubectl get pods -n $NS   # no controller/launcher/requester pods
```

## Current status

This is fixed on current checkouts — teardown now includes the FMA controller
chart prefix in its managed-release cleanup, so the release is uninstalled with
everything else. The fix landed in
<https://github.com/llm-d/llm-d-benchmark/pull/1843> (closed
<https://github.com/llm-d/llm-d-benchmark/issues/1820>); "checkouts before the
fix" means a checkout that predates that merge.

Keep the explicit uninstall as a fallback for pre-fix checkouts and as a
post-teardown sanity check for now. **Retire this reference** (and drop the
explicit uninstall from the workflow) once the teardown-cleanup fix has been
stable across a few release cycles and pre-fix checkouts are no longer in use —
at that point "checkouts before the fix" no longer describes anything anyone
runs, and carrying the workaround only adds noise.

## Separate leftover: the `llm-d-prism` deployment survives teardown

On current FMA (v0.7.0+ / recent nightly), `run` deploys an `llm-d-prism`
component (observability; added in llm-d/llm-d-benchmark#2048) that carries the
label **`llm-d-benchmark.ai/persist=true`**. `llmdbenchmark teardown` intentionally
leaves it in place — so after a "Teardown complete" you will still see a running
`llm-d-prism-*` pod plus its Service and Route. This is **not** the helm leak
above; it is a deliberately-persisted component. But it **blocks a clean
next-standup check** (`kubectl get pods -n $NS` is not empty) and lingers across
model switches.

If you need a fully clean namespace before the next model (recommended between
models so the readiness/clean checks are unambiguous), remove it explicitly:

```
kubectl delete deployment,service,route -n $NS -l app.kubernetes.io/name=llm-d-prism --ignore-not-found
# if the pod is wedged in Error/Terminating, also:
kubectl delete pod -n $NS -l app.kubernetes.io/name=llm-d-prism --force --grace-period=0 --ignore-not-found
```

Then `kubectl get pods -n $NS` should be empty. (Observed repeatedly on v0.7.0,
2026-10-21 — teardown left `llm-d-prism` running every cycle.)
