# Qwen local development and streamed chat

## Select the development model

Use the existing local `Qwen3.8-27B-4bit` checkpoint on MLX / Metal for all current and remaining ASG tasks on the owner's Mac that require live inference. Use the exact server model ID `Qwen3.8-27B-4bit` at `http://127.0.0.1:8765/v1`. Verify runtime health and model identity before recording live evidence. If the runtime is unavailable or reports a different model, keep the affected acceptance pending and continue eligible independent work. Keep dated observations and deterministic fixtures tied to their original model identities.

1. In ASG, open **Set up runtime** and choose **Local files**.
2. On the owner's Mac, use the existing checkpoint at `~/ASG-model-downloads/Qwen3.8-27B-4bit`. Choose **Find local models** and select **Qwen3.8-27B-4bit**.
3. Use the existing MLX environment's Python executable. Choose **Save runtime setup**, then **Start selected model**.
4. Wait for **Runtime reports ready** and **MLX / Metal**. Under **Connect project chat**, verify that the URL is `http://127.0.0.1:8765/v1` and the exact model ID is `Qwen3.8-27B-4bit`. If the app has yet to save the connection, choose **Connect & save**.
5. Choose **Test inference**. Confirm that the test completes and shows the exact requested model ID before using it for development.

This flow uses existing local files. See [runtime setup](RUNTIME_SETUP.md) for supported backends and setup limits. Earlier measurements and configuration details remain in the [historical BF16 record](LOCAL_QWEN.md) and [delivery history](../history/PROGRESS.md).

On 5 November 2026, the installed ASG app loaded this checkpoint on MLX / Metal. The loopback model inventory advertised the exact ID above. The in-app connection test completed in 5,520 ms, with first text at 4,923 ms. This was one bounded connection test. Full chat-to-preview acceptance, memory fit and usable context still need separate evidence.

## Streaming and visible state

The bridge accepts `stream=true` and sends SSE events immediately:

- `status`: thinking during prompt processing; writing once output begins.
- `message`: actual incremental token text in `choices[].delta.content`.
- `ping`: one-second heartbeats while waiting.
- A finish reason followed by `[DONE]` for completed responses.
- `error` on failed/interrupted generation; no successful completion marker.

Chat shows an always-visible spinner and Thinking / Writing response / Checking the update / Applying changes labels. The temporary response bubble grows as human-readable summary text arrives. These are processing phases, not a display of private reasoning. Structured edit JSON is not shown as ordinary prose. Standalone Discuss chat also receives incremental output.

The application definition is changed only after the whole stream completes, its edit validates, and storage succeeds. Truncated output, early EOF, errors and cancellation preserve the last working application. A Stop action closes the request; the runtime checks cancellation between generated tokens and bounded prefill chunks. Stop is disabled while an already validated revision is being saved.

Limits: 15-second connection/header timeout, 30-second inactive-stream timeout, 180-second total generation limit, 4096 input tokens and at most 4096 output tokens. The runtime defaults to 256 output tokens; conversation controls remain limited to 2048, while reviewed full-file source proposals request 4096. Heartbeats keep legitimate prompt processing from being mistaken for an inactive connection. MLX prefill checks cancellation/deadline every 256-token chunk. A single native kernel cannot be interrupted mid-execution. One inference operation runs at a time; overlapping requests return HTTP 429. The old nonstreaming JSON response remains supported for compatible clients, but the app uses SSE with this runtime.

## Validation

Each JSON object in a chat request must use unique field names. The bridge
returns HTTP 400 for duplicate fields before inference in either response mode.

For JSON and streaming requests, the HTTP bridge accepts an exact JSON
integer from 1 through 4096 in either `max_tokens` or
`max_completion_tokens`. Send only one field. Omitting both defaults to 256.
Sending both fields or a zero, negative, oversized, fractional, boolean,
string or null value returns HTTP 400 before inference. The bridge never
coerces or silently clamps a requested output budget. This contract does
not establish a model-specific verified context window or token-accounting
profile; the existing input limit and per-backend checks still apply.
Once the bridge counts the exact prompt, exceeding the input ceiling or the
checkpoint's declared total context returns HTTP 400 for a JSON request. A
stream that has already started sends an actionable `error` event without
`[DONE]`. The caller can shorten the request (or reduce the output budget for
the total context limit) and retry; these checks do not verify usable context
capacity.

Run regular Flutter checks. Before opting into a live test on this Mac, check that `http://127.0.0.1:8765/health` reports ready on MLX / Metal and `http://127.0.0.1:8765/v1/models` advertises `Qwen3.8-27B-4bit`. The opt-in Flutter tests explicitly select that model. Run live tests serially and record the tested revision, model, host and actual result.

```sh
flutter analyze
flutter test
flutter test test/application_loop_test.dart --dart-define=ASG_REAL_INFERENCE=true --plain-name 'real local Qwen instruction'
python3 -B tools/test_qwen_streaming_server.py
```

Tests cover partial UTF-8/SSE packets, token arrival before completion, timeouts, truncation/EOF, escaped summary text, visible phases, cancellation and validation-before-preview-refresh. See PROGRESS.md for build results.

References: [MLX LM](https://github.com/ml-explore/mlx-lm) and the model's local Apache-2.0 licensing records described in LOCAL_QWEN.md.

## Discuss and Plan drafts

From the workspace Chat header, choose **Discuss, plan and review**, then **Discuss**, **Plan** or **Review**. This conversation is saved separately from application-edit chat. Plan asks for requirements, feasibility, tasks, acceptance criteria and risks; saved requests and replies carry Plan labels and replies remain explicitly unapproved. Switching back to Discuss changes the next prompt; reopening defaults to Discuss and retains history. Mode selection is locked while a request is active. Neither conversational mode has application, filesystem or command tools, and typing an approval cannot execute a plan. Plans may include validated `asg-build` starter contracts or `asg-tasks` planning proposals. The UI previews tasks and records explicit approval/withdrawal for the exact saved Plan, project, requirements and prototype context. Task import requires a separate additive action and invalidates old approval. Only the fixed starter contract can reach Build, with separate operation consent; general planning prose and advisory Review cannot execute work. The conversation uses up to 1536 output tokens within the existing runtime's limits; truncated replies remain errors.

Opt-in real planning verification (run alone, with the existing local runtime):

```sh
flutter test test/planning_conversation_test.dart --dart-define=ASG_REAL_INFERENCE=true --plain-name 'real local Qwen planning'
```


## Backend capability discovery (F15 foundation)

Run `python -B tools/qwen_server.py --capabilities` with the selected runtime
Python executable. This prints versioned JSON without requiring `--model`,
importing inference frameworks, loading weights, probing devices or downloading.
Host support and missing dependencies are distinct from readiness: null device
and model readiness mean unverified, even when all modules are installed. Memory
adequacy is not measured. CPU/CUDA execution remains unsupported.

Existing `--backend auto|mlx|torch` launch arguments remain available. Auto retains
the legacy MLX-module preference and does not retry another backend after a load
failure. Explicit incompatible hosts, missing dependencies and quantized Torch
folders fail before weight loading. Torch currently means legacy Apple MPS with
unquantized compatible weights; an MLX quantized folder cannot be reused there.
Health identifies the loaded backend/device; discovery alone never reports ready.

The managed app extracts both `qwen_server.py` and its sibling `qwen_backends.py`.
Existing setup records/defaults are unchanged. Helper preparation honors the explicit backend selection without fallback; Auto retains the legacy preference. Preparation never loads weights and does not establish model or memory readiness. The discovery CLI is a bounded
foundation: app capability display, persisted explicit backend/device selection,
consented fallback and CPU/CUDA delivery still require later F15 increments.
Actual MLX generation/restart evidence is saved separately in
[the bounded regression record](../development/acceptance/2026-10-31-backend-contract/mlx-smoke.json).


## Torch prompt and completion token metrics

The shared Torch generation path tokenizes the rendered chat template once with
truncation disabled and checks the exact input tensor length before device
transfer. Inputs over the bridge's existing 4,096-token policy fail without
generation or silent truncation. Successful JSON and SSE completion `metrics`
include `prompt_tokens` from those tensors and `completion_tokens` from the
returned sequence length minus the prompt, including generated special/end
tokens. Counts describe model tokens, not displayed text fragments.

These counts do not establish the model's verified total context capacity,
remaining usable context, memory fit or backend support. The output-token
ceiling remains the exact caller request. Other backends retain their existing
metrics; missing counts are unavailable rather than zero. CPU remains
experimental and opt-in; deterministic tensor/HTTP regressions are not live
inference acceptance.


### MLX prompt-token accounting

The MLX bridge encodes the rendered chat once with truncation disabled, using
mlx-lm's BOS-prefix rule. The same token list is checked against the bridge's
4096-input policy and passed to streaming generation. Completion metrics include
`prompt_tokens` from that list and `completion_tokens` from the helper's final
`generation_tokens` (including nontext/end tokens); no completion count is invented
if the helper supplies no result. Counts are not text-fragment counts. This policy
is not a verified model-specific total context window or a new inference benchmark.


### Checkpoint-declared total context guard

The managed bridge reserves the entire requested output budget against the
local checkpoint's `text_config.max_position_embeddings` (or the top-level
field only when `text_config` is absent). Exact untruncated input plus requested
output must fit before device transfer or generation. Oversized requests fail;
the bridge never silently truncates input or reduces output. RoPE scaling and
user-declared preset notes cannot enlarge this limit. Missing metadata leaves
capacity unknown and retains the independent 4096 input/output policies;
malformed present limits fail before loading. A checkpoint declaration is not
measured usable capacity, verified identity, memory fit or live-inference evidence.


### Read-only advertised request limits

For MLX and Torch, `GET /v1/models` includes optional `asg_request_limits`
on the exact advertised model entry: schema_version 1, max_input_tokens 4096,
max_output_tokens 4096 and checkpoint_context_tokens (positive declaration or
null when unknown). The settings dialog's existing **Inspect draft model ID**
action displays these as server assertions, including the combined prompt plus
requested-output rule when declared. Older servers remain compatible and
unknown; malformed selected-entry metadata fails privately. Inspection does not
run generation, save settings, apply profile notes or alter request budgets.
These policy/declaration values do not verify usable context, model identity,
format compatibility, memory fit or successful inference.

### Explicit draft JSON format observation

In Local model settings, **Test JSON format** sends a fixed harmless request to
that dialog's draft connection and exact model ID, without applying the draft.
It asks for `{"asg_probe":"ok"}` and requires a completed, duplicate-free JSON
object with exactly that member/value. Markdown, prose, extra members and
partial output fail. This uses the same 30-second, 4096-character and fixed
256-output-token limits as Test model; **Stop test** closes the app connection
without promising server-side cancellation. Raw response/error text is omitted.

This is one temporary prompt-format observation, not an API `response_format`
request or general schema/tool compatibility test. It does not authenticate
loaded weights, establish a context budget or enable model support. Results are
not saved to profiles or settings. Save remains a separate action. No new real
model validation is implied by the deterministic HTTP/controller regressions.

The bundled local bridge accepts plain text requests, including
`response_format: {"type": "text"}`. Requests for JSON mode, JSON Schema,
tool calls or tool history return HTTP 400 before generation, including
when the caller requested streaming. Omitted or neutral options (such as an
empty tool list or `tool_choice: "none"`) still allow text chat.
