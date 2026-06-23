# Known Model KV Architecture Parameters

Used to compute KV bytes per token without requiring the user to look up internal model details.

| Model | num_layers | num_kv_heads | head_dim | Notes |
|---|---|---|---|---|
| meta-llama/Llama-3.1-8B | 32 | 8 | 128 | GQA |
| meta-llama/Llama-3.1-70B | 80 | 8 | 128 | GQA |
| meta-llama/Llama-3.1-405B | 126 | 8 | 128 | GQA |
| meta-llama/Llama-3.2-1B | 16 | 8 | 64 | GQA |
| meta-llama/Llama-3.2-3B | 28 | 8 | 128 | GQA |
| meta-llama/Llama-3.3-70B | 80 | 8 | 128 | same as 3.1-70B |
| Qwen/Qwen2.5-7B | 28 | 4 | 128 | GQA |
| Qwen/Qwen2.5-14B | 48 | 8 | 128 | GQA |
| Qwen/Qwen2.5-32B | 64 | 8 | 128 | GQA |
| Qwen/Qwen2.5-72B | 80 | 8 | 128 | GQA |
| Qwen/Qwen3-8B | 36 | 8 | 128 | GQA |
| Qwen/Qwen3-14B | 40 | 8 | 128 | GQA |
| Qwen/Qwen3-32B | 64 | 8 | 128 | GQA |
| Qwen/Qwen3-72B | 80 | 8 | 128 | GQA |
| Qwen/Qwen3-235B-A22B | 94 | 4 | 128 | MoE, GQA; use active layers ≈ 94 |
| Qwen/Qwen3.6-32B | 64 | 8 | 128 | estimate; verify from model config |
| mistralai/Mistral-7B-v0.3 | 32 | 8 | 128 | GQA |
| mistralai/Mistral-Nemo-12B | 40 | 8 | 128 | |
| mistralai/Mixtral-8x7B | 32 | 8 | 128 | MoE, same KV shape per layer |
| mistralai/Mistral-Small-3.1-24B | 40 | 8 | 128 | |
| google/gemma-2-9b | 42 | 8 | 256 | |
| google/gemma-2-27b | 46 | 16 | 256 | |
| openai/gpt-oss-120b | 96 | 8 | 128 | estimate based on 120B scale; verify |
| ibm-granite/granite-3.3-8b-instruct | 32 | 8 | 128 | |
| ibm-granite/granite-3.3-2b-instruct | 24 | 8 | 64 | |

## GPU Memory Reference

| GPU | Total VRAM | Notes |
|---|---|---|
| A100 40GB SXM | 40 GiB | |
| A100 80GB SXM | 80 GiB | |
| H100 80GB SXM5 | 80 GiB | faster HBM3 than A100 |
| H200 141GB SXM | 141 GiB | |
| A10 24GB | 24 GiB | |
| L40 48GB | 48 GiB | |
| L40S 48GB | 48 GiB | |
| L4 24GB | 24 GiB | |
| RTX 4090 | 24 GiB | |

## Weight Memory Estimation (approximate fp16)

Rule of thumb: **2 bytes × num_parameters** for fp16 weights.

- 7B model → ~14 GiB
- 8B model → ~16 GiB
- 13B model → ~26 GiB
- 32B model → ~64 GiB
- 70B model → ~140 GiB (requires TP≥2 on 80GB GPUs)
- 72B model → ~144 GiB
- 120B model → ~240 GiB (requires TP≥4 on 80GB GPUs, or fp8)
- 405B model → ~810 GiB

For fp8 weights: halve the fp16 estimate.
For fp4/int4: quarter the fp16 estimate.
For bfloat16: same as fp16.

In practice vLLM over-allocates slightly for activations and CUDA graphs (~2-5 GiB per GPU). Subtract an additional 5 GiB from available memory to be safe.
