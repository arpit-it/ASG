# Existing 9B MLX synthetic regression — 2 November 2026

Issue #396 / F22, branch `396-live-mlx-profile`. Real offline inference on this Mac; not fixtures or full product acceptance. Runtime source: main `d3767cc6c9514ada6e0d6a22d98f428c7f828b89` (PR #431). Exact bridge/probe hashes are in `observations.json`. This change does not alter application/inference runtime source.

The existing ignored 9B conversion and project-local MLX environment ran on isolated loopback port 18765. Sandbox Metal access initially failed; authorized native-process access loaded successfully. No download, installation, settings change or stable-app replacement occurred. The owned process was stopped after validation.

Warm requests passed: JSON completion, structured JSON SSE with nine content chunks, disconnect after actual generated content, idle within 0.111 seconds and successful retry. Bridge-reported prompt/completion counts: 20/2 and 31/10. These exercise actual tokenization/generation but are not an independent count audit. Reported throughput: 79–144 tokens/second. MLX process high-water memory: 5.32 GB, not reset between requests or a per-request/worst-case capacity measurement. Single warm observations are not a benchmark distribution; SSE timing starts after headers.

One observed Safetensors file totals 5,038,162,465 bytes. Config/tokenizer/index hashes are recorded; weights are counted, not hashed. Original revision/license and HTTP identity are not authenticated. The 262144-token checkpoint declaration is NOT verified usable context; only tiny prompts were tested. No full 4096-token workload, deadline/native-kernel preemption, app Stop/manual acceptance, second/larger-model profile or new platform support is claimed. F22/F15 remain unchecked. Remaining profiles/evidence stay Pending; external-platform acceptance remains Deferred #400.

## Explicit reproduction

Start an operator-owned offline bridge with an existing checkpoint, matching model ID and free loopback port. From `asg/`:

```sh
tools/.mlx-venv/bin/python -B tools/live_mlx_profile.py --origin http://127.0.0.1:18765 --checkpoint .runtime-models/qwen3.5-9b-4bit --model Qwen3.5-9B --source-revision d3767cc6c9514ada6e0d6a22d98f428c7f828b89 --output /private/tmp/new-mlx-observations.json --confirm-live
```

Run alone against your owned idle bridge; disconnect testing interrupts its own request. The probe never launches/downloads a model. Source revision is operator-declared. Output paths must be new. Reports exclude prompts, response text, endpoints, paths and arbitrary server fields. Optimized Python refuses execution. Socket reads and stream byte/time budgets are bounded. CI refusal tests validate CLI behavior only, never live inference.
