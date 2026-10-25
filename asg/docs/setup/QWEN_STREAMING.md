# Qwen timeout fix and streamed chat

## Current runtime

The app's existing endpoint (`http://127.0.0.1:8765/v1`) and model ID (`Qwen3.5-9B`) now use a project-local MLX runtime and a 4-bit conversion of the already downloaded Qwen weights. Original files at `/Users/arpitsinha/ARG-model-downloads/qwen3.5-9b` were preserved. No replacement model was downloaded.

The former PyTorch/MPS BF16 path loaded roughly 19 GB of weights and timed out on structured edits. A direct test of the optimized model loaded in 2.59 seconds, finished a short structured-edit response in 5.89 seconds total, reported 67.8 generation tokens/second and 5.29 GB peak memory. These are measurements on this Mac, not guaranteed performance on other hardware.

The previously failing opt-in Flutter integration test now passes through the real local streaming provider with built-in edits disabled. It validates a custom title/theme change, a saved new application revision, thinking/writing/applying phases, and multiple growing summary chunks before completion.

## Restart on this Mac

```sh
cd /Users/arpitsinha/AndroidStudioProjects/ASG/asg
HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 tools/.mlx-venv/bin/python -B tools/qwen_server.py \
  --model .runtime-models/qwen3.5-9b-4bit --model-id Qwen3.5-9B
```

The model cache and virtual environment are ignored by Git. Pinned Python dependencies are in `tools/requirements-mlx.txt`. The installed MLX Metal wheel targets macOS 26+; this environment was verified on the user's macOS 27 Apple Silicon machine.

On a new suitable Mac, create a project-local environment with `python3 -m venv tools/.mlx-venv`, install `tools/requirements-mlx.txt` there, then convert an existing compatible checkpoint into a **new** output folder:

```sh
HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 tools/.mlx-venv/bin/python -m mlx_lm convert \
  --hf-path /path/to/existing/qwen3.5-9b \
  --mlx-path /path/to/new/qwen3.5-9b-4bit -q --q-bits 4 --q-group-size 64
```

Do not overwrite original weights. Provisioning another environment/conversion is explicit setup, not an automatic model download. The setup page's Prepare action now recognizes an existing MLX environment; Torch/Transformers remains a legacy fallback. For managed startup choose the MLX environment's absolute Python executable and the converted checkpoint folder. If the CLI runtime above is already running, the app connects to it and will not kill it as an app-owned process.

## Streaming and visible state

The bridge accepts `stream=true` and sends SSE events immediately:

- `status`: thinking during prompt processing; writing once output begins.
- `message`: actual incremental token text in `choices[].delta.content`.
- `ping`: one-second heartbeats while waiting.
- A finish reason followed by `[DONE]` for completed responses.
- `error` on failed/interrupted generation; no successful completion marker.

Chat shows an always-visible spinner and Thinking / Writing response / Checking the update / Applying changes labels. The temporary response bubble grows as human-readable summary text arrives. These are processing phases, not a display of private reasoning. Structured edit JSON is not shown as ordinary prose. Standalone Discuss chat also receives incremental output.

The application definition is changed only after the whole stream completes, its edit validates, and storage succeeds. Truncated output, early EOF, errors and cancellation preserve the last working application. A Stop action closes the request; the runtime checks cancellation between generated tokens and bounded prefill chunks. Stop is disabled while an already validated revision is being saved.

Limits: 15-second connection/header timeout, 30-second inactive-stream timeout, 180-second total generation limit, 4096 input tokens and at most 2048 output tokens. Heartbeats keep legitimate prompt processing from being mistaken for an inactive connection. MLX prefill checks cancellation/deadline every 256-token chunk. A single native kernel cannot be interrupted mid-execution. One inference operation runs at a time; overlapping requests return HTTP 429. The old nonstreaming JSON response remains supported for compatible clients, but the app uses SSE with this runtime.

## Validation

Run regular Flutter checks and the opt-in live test:

```sh
flutter analyze
flutter test
flutter test test/application_loop_test.dart --dart-define=ASG_REAL_INFERENCE=true --plain-name 'real local Qwen instruction'
python3 -B tools/test_qwen_streaming_server.py
```

Tests cover partial UTF-8/SSE packets, token arrival before completion, timeouts, truncation/EOF, escaped summary text, visible phases, cancellation and validation-before-preview-refresh. See PROGRESS.md for build results.

References: [MLX LM](https://github.com/ml-explore/mlx-lm) and the model's local Apache-2.0 licensing records described in LOCAL_QWEN.md.

## Discuss and Plan drafts

From the workspace Chat header, choose **Discuss and plan**, then **Discuss** or **Plan**. This conversation is saved separately from application-edit chat. Plan asks for requirements, feasibility, tasks, acceptance criteria and risks; saved requests and replies carry Plan labels and replies remain explicitly unapproved. Switching back to Discuss changes the next prompt; reopening defaults to Discuss and retains history. Mode selection is locked while a request is active. Neither conversational mode has application, filesystem or command tools, and typing an approval cannot execute a plan. Plans are model-written prose, not a validated task schema or a working approval/build engine. The conversation uses up to 1536 output tokens within the existing runtime's limits; truncated replies remain errors.

Opt-in real planning verification (run alone, with the existing local runtime):

```sh
flutter test test/planning_conversation_test.dart --dart-define=ASG_REAL_INFERENCE=true --plain-name 'real local Qwen planning'
```
