# Historical BF16 Qwen setup

ASG is a Flutter application targeting Android, iOS, web, macOS, Windows and Linux. Included platform runners do not establish tested device support. Managed MLX setup and the current independent Flutter web generator host are macOS-specific; other platforms retain supported app features and runtime connection controls.

The commands and measurements below describe the earlier Torch/BF16 experiment. For the active MLX setup, use [Qwen streaming](QWEN_STREAMING.md). They are retained for reproducibility, not the recommended current startup path.

**Current runtime update:** Qwen now uses the verified local 4-bit MLX streaming backend. The earlier Torch timeout/nonstreaming notes below are historical. See [QWEN_STREAMING.md](QWEN_STREAMING.md) for current setup, limits and successful real-edit verification.

## Verified checkpoint and runtime

Existing model folder: `/Users/arpitsinha/ARG-model-downloads/qwen3.5-9b`.
The index resolves four existing Safetensors shards totaling 19,306,216,416 bytes. Configuration identifies `Qwen3_5ForConditionalGeneration`, BF16. This is not a 4-bit MLX/GGUF checkpoint. Original local model card and Apache-2.0 license are also present at `/Users/arpitsinha/Qwen3.5-9B`; the selected downloads folder lacks a license file. No weights were downloaded, copied, or converted.

Existing runtime used read-only: `/Users/arpitsinha/ComfyUI-Installs/mac_instance/ComfyUI/.venv/bin/python` (Transformers 5.16.1, Torch 2.12.1). Accelerate 1.15.0 was installed only into this project's ignored `tools/.runtime-deps` directory, without modifying the ComfyUI environment. This reuse is machine-specific; a dedicated pinned inference environment is future work.

## Start the bridge

From the Flutter app directory:

```sh
cd /Users/arpitsinha/AndroidStudioProjects/ASG/asg
/Users/arpitsinha/ComfyUI-Installs/mac_instance/ComfyUI/.venv/bin/python -B tools/qwen_server.py \
  --model /Users/arpitsinha/ARG-model-downloads/qwen3.5-9b
```

Wait for `Ready at http://127.0.0.1:8765/v1`. The bridge binds only to loopback, uses local files only and disables remote model code. Stop it with Ctrl+C in that terminal to release model memory. On a clean checkout install the missing helper into the same project-local folder with:

```sh
/Users/arpitsinha/ComfyUI-Installs/mac_instance/ComfyUI/.venv/bin/python -m pip install --no-deps --target tools/.runtime-deps accelerate==1.15.0
```

## Use the Flutter app

Open dashboard Settings. Model ID: `Qwen3.5-9B`.

- macOS: `http://127.0.0.1:8765/v1`
- Android Emulator debug build: `http://10.0.2.2:8765/v1`
- Web served on localhost: use `http://127.0.0.1:8765/v1`; local browser origins are supported. Hosted HTTPS pages are not configured to access this HTTP bridge.
- Physical phones: access to the Mac's model is not configured. Do not use the Mac's loopback address from a phone.

Save settings, then choose **Test model** for a real request. Open a project and choose **Discuss with Qwen 9B** for a saved per-project conversation. Chat and configuration now use transactional native/IndexedDB storage with retained preference migration; the experiment originally used preferences. The latest eight messages plus project description are sent as a textual transcript. Discuss has no filesystem or command tools; the other mode chips do not enable execution.

The debug-only Android network policy permits local HTTP to localhost and the Android Emulator host alias. This does not enable network model access in a release APK.

## Verification and limits

The checkpoint loaded on Apple Metal. A real request returned `Ready to plan software.` in 15.64 seconds (single cold request, not a throughput benchmark). No 16K context, tool-use, quantization, or memory peak benchmark is claimed. Bridge limits: 32 KB request body, 4096 input tokens, 256 output tokens, one generation at a time, generation max-time 90 seconds checked by Transformers between steps. Client timeout is 120 seconds. Cancelling the UI request disconnects the client; it does not interrupt an already running server generation. The API currently returns completed responses rather than token streaming.

API shape reference: [llama.cpp server documentation](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md). This project uses a small Transformers bridge, not an installed llama.cpp runtime.


### Advisory checkpoint memory estimate

After scanning/selecting a complete local checkpoint, Inspect capabilities shows a conservative new-load budget on an inspected available Apple unified-memory backend. Working memory is estimated as 1.25 times measured weight bytes plus 4 GiB for runtime/cache, with another 6 GiB reserved for OS/apps. Total-budget limits, current free/reclaimable memory pressure and unknown observations are separate. Auto uses the existing dependency preference; incompatible Torch/MPS quantized weights and unavailable/unverified devices cannot yield an estimated-fit result.

This heuristic is not architecture/context-specific peak measurement or successful inference. Context/activation/cache needs can exceed it; an existing loaded model gives no RAM credit. Inspect again after memory changes and rescan after checkpoint changes. The estimate does not start, block, switch or unload a runtime, change settings or download weights. CPU/CUDA milestones remain unavailable.
