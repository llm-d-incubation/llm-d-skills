# Model swap: use `model.*`, not `common.model.*`, on BOTH commands

## The gotcha

To point a run at a different model you must override four keys:

```
--set model.name=<HuggingFaceID> \
--set model.shortName=<short-slug> \
--set model.path=models/<HuggingFaceID> \
--set model.huggingfaceId=<HuggingFaceID>
```

Two mistakes both produce a silent wrong-model run:

### 1. Wrong key prefix (`common.model.*`)

`common:` is expanded to the config root before the `--set` overrides merge, so
`common.model.name` is an orphan key that matches nothing. A dry-run render shows
the model as `<unset>` and the run silently uses the scenario default. Always use
the top-level `model.*` keys.

**Verify with a dry run:** the override log line must read
`override: model.name '<old>' -> '<new>'` where `<old>` is a real value. If it
reads `'<unset>' -> '<new>'`, the key is wrong.

### 2. Overrides on standup only, not run

The run's `detect_endpoint` derives the launcher name from the run's own model
config. If you pass the model `--set` flags on standup but omit them on run, the
run looks for the default launcher (the scenario default, e.g. a 4B model),
fails to find your model's endpoint, and — depending on the harness path — can
exit 0 with a fake "success" and 0 iterations. **Pass the identical model `--set`
flags on both standup and run.**

## Why `model.name` must stay the repo ID

`model.name` feeds the derived Helm release name (`model_id_label`). A filesystem
path there produces a leading-dash release name (e.g. `-model-c-...-fma-dp`),
which `helm upgrade --install` parses as a flag (`Error: unknown shorthand flag`).
To load from a local staged copy, keep `model.name` as the repo ID and use
`fma.launcher.loadModelFromLocalDir` instead — see `big-models.md`.

## Observed context

The 4B fallback signature (run "succeeds", 0 iterations, results show
`Qwen/Qwen3-4B` instead of the intended model) was observed with the
**Qwen3-4B** scenario default. The mechanism is model-independent — any scenario
default will silently win if the run's model `--set` is omitted.
