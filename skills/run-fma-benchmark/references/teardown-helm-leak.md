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
