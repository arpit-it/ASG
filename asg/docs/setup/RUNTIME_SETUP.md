# Runtime setup

ASG is a Flutter application targeting Android, iOS, web, macOS, Windows and Linux. Included platform runners do not establish tested device support. Managed MLX setup and the current independent Flutter web generator host are macOS-specific; other platforms retain supported app features and runtime connection controls.

Use the previously verified 4-bit MLX environment/checkpoint on Apple Silicon. The endpoint was unavailable during this audit; use [streaming setup](QWEN_STREAMING.md) for explicit startup and live checks. Torch/BF16 details below describe the legacy fallback.

Open the **Set up runtime** chip/FAB in the landing screen's upper-right corner. Runtime setup follows MVC: RuntimeSetup/ModelCandidate → RuntimeSetupController → RuntimeHost, RuntimeConnection and stores → RuntimeSetupScreen.

## Already downloaded

In the macOS app, select **Local files**, choose a model folder or a collection of model folders, then **Find local models**. A checkpoint needs config.json, tokenizer files and complete Safetensors weights; selecting a lone weight file is insufficient. Scanning includes the selected directory and up to three child levels, bounded to 200 folders.

For this Mac, the existing checkpoint is `/Users/arpitsinha/ARG-model-downloads/qwen3.5-9b`. Initial managed inference supports architecture `Qwen3_5ForConditionalGeneration` through the bundled Transformers bridge on Apple Metal. The bundled bridge also supports the existing locally converted Qwen MLX checkpoint with a compatible MLX environment. Other architectures, GGUF, incomplete checkpoints and Git LFS pointer files remain unsupported; no arbitrary model compatibility is implied. Linked weights outside the checkpoint directory are rejected; select a self-contained downloaded copy.

## Download from a repository

Choose **Repository**, enter a public Hugging Face ID such as `Qwen/Qwen3.5-9B`, its HTTPS repository URL, or another public HTTPS Git repository URL. Select a revision/branch and an existing parent folder. Press **Download model & validate** explicitly to begin the transfer.

A new repository-named directory is created. Existing directories are never overwritten. Hugging Face uses the selected Python environment's huggingface_hub package to download configuration/tokenizer/Safetensors artifacts without Python repository code. Other HTTPS Git hosts use Git with interactive prompts and global/system Git configuration disabled; actual committed weight files are required. Generic Git LFS pointer repos are rejected after cloning; use their Hugging Face equivalent or an already complete local checkout.

Downloads can be many gigabytes. Check the repository's model license and disk needs before beginning. No model download runs automatically on page open or on local-file selection. Transfers continue while the app remains running, with bounded log output and a six-hour timeout. There is no pause/resume/cancel UI in this increment. Interrupted partial folders are retained; they are not silently overwritten on retry. Private/gated repository authentication and download-size previews are not implemented.

## Prepare and launch

**Backend for next launch** offers Auto (the legacy MLX-first dependency preference), MLX / Metal and Torch / MPS. **Save runtime setup** persists this choice and the form without starting/downloading a model or changing the active chat connection. Reopening setup restores the saved choice. Starting passes the exact choice; an explicit choice never retries another backend. Torch/MPS requires compatible unquantized weights; MLX quantized folders cannot be assumed compatible. CPU/CUDA remain unavailable. Selection alone does not inspect dependencies, devices, model compatibility or memory adequacy; the bridge validates before loading. Prepare honors the current backend choice, including an unsaved form choice. Auto retains the legacy module preference. Explicit MLX never prepares Torch; explicit Torch checks MPS and prepares its pinned app-local helper even when MLX is installed. Missing dependencies fail without fallback. Success checks dependencies only; model loading and memory adequacy remain unverified.

**Inspect capabilities** explicitly checks dependencies and queries available Metal/MPS device APIs in the chosen Python without loading model weights. It shows a sanitized detected host, backend dependency availability, device available/unavailable/unknown, and scanned checkpoint metadata restrictions (Torch rejects quantized checkpoints). Missing packages and unsupported hosts skip device imports; API/import errors remain unknown with retry/environment guidance. Device availability and passing metadata restrictions do not prove successful model loading, inference or memory adequacy. Auto follows the same legacy dependency rule as launch; an unavailable preference is not silently replaced. Launch revalidates current files/environment. Scanned metadata and device availability are inspection-time observations, not live watchers.

Discovery does not install packages, load weights, download, save settings, change chat or stop a running model. Python/backend edits, a new scan/selection, preparation and download invalidate the prior result. Inspect again after changing files or packages externally. Output is bounded to 64 KiB and the helper has a ten-second deadline with owned-process cleanup; raw stderr/invalid output are hidden. Failed discovery supports retry. Closing setup ignores late results; a dispatched helper finishes or is killed within its bounded deadline. Other platforms keep connection controls and do not advertise managed discovery.

The health panel displays only recognized ready-server backend/device pairs, labeled as a runtime report. Missing, unfamiliar or inconsistent pairs remain unknown; loading, failures and unreachable health do not retain a loaded identity. These are server reports, not independent device probes or memory adequacy verification. Existing HTTP connection controls remain usable on other platforms. F15 model/memory readiness and non-Apple CPU/CUDA milestones remain outstanding.


Choose an existing Python environment with compatible Torch and Transformers. On this machine, the previously verified interpreter is `/Users/arpitsinha/ComfyUI-Installs/mac_instance/ComfyUI/.venv/bin/python`; enter it or select it with the executable picker. The application has no hardcoded interpreter path.

**Prepare runtime helper** first recognizes an installed MLX runtime and verifies its imports without helper installation. For the legacy Torch path it verifies Torch/Transformers and Apple Metal, then installs only Accelerate 1.15.0 into the app-support runtime directory. It does not install or replace Torch/Transformers or modify the selected Python environment. Downloading from Hugging Face additionally requires huggingface_hub in that environment; other Git hosts require Git.

Select a compatible checkpoint and press **Start selected model**. The bundled trusted bridge is extracted into application support and launched with argument arrays, not a shell. It binds only to localhost:8765. Chat settings are saved only after /health reports the expected model ID and path. The runtime model ID is derived from the selected folder name, and is passed explicitly to the bridge.

A running external runtime is shown as external: the app will not kill or replace it. **Connect & save** connects project chat to the model ID/URL you enter. **Test inference** requests a real model response. **Stop runtime** targets only a process launched and owned by this app. A bridge launched by the app watches the parent PID and exits when the app exits. Closing the setup page does not stop an already running managed runtime. If setup is closed during loading, reopen the page to inspect its status and connect after it is ready.

## Discovery evidence and limits — issue #334

| Client/host | Managed dependency discovery | Evidence and limit |
| --- | --- | --- |
| macOS Apple Silicon | Implemented | Actual shipped-helper subprocess and existing MLX environment dependency JSON; automated injected setup interaction at 320px/text scale 1.5. No new manual native setup acceptance or inference. |
| Web | Unavailable in production | Connection controls retained. Actual Chrome exercises injected setup UI; that does not enable web process execution. |
| Android/iOS/Windows/Linux clients | Unavailable in production | Existing-runtime connection controls remain. Portable subprocess fixtures do not advertise managed host support. |
| CPU/CUDA backend | Unavailable | No device inference or adequacy claim. F15 remains In progress. |

The source-bound no-weight observation is `development/acceptance/2026-10-31-backend-discovery/discovery.json`. It is separate from earlier actual MLX generation evidence and the per-identity F17 reports. No historical report is relabeled as current support.

## Platforms and security

Local model scanning/download/process management is implemented for macOS. Android, iOS, Windows, Linux and web show connection controls and an explicit macOS setup explanation; they do not pretend to run Apple Metal inference. Android Emulator uses `http://10.0.2.2:8765/v1`; macOS and localhost web use `http://127.0.0.1:8765/v1`. Physical-phone connectivity remains unconfigured. Connection checks currently target this bridge's /health schema.

The user explicitly approved disabling macOS App Sandbox for this desktop build on 25 October 2026 so it can invoke a selected host Python environment. This is an app-specific entitlement change, not a change to macOS system protections. The macOS app and its Python process run with host user permissions; no filesystem/process isolation is claimed. Existing sandboxed Studio preference keys are copied into missing standard preference keys before Flutter starts, without overwriting newer records or deleting the old container. Migration errors stop startup visibly rather than showing an empty project list.

Future distribution should evaluate a signed managed helper or other narrower host integration. Generated repository Python code is never loaded by this flow (`trust_remote_code=False`), and arbitrary source synthesis/execution remains unavailable. The separate approved fixed Flutter web generator uses trusted installed tools; see [generation](../architecture/GENERATION.md).

## Historical setup validation

These results apply to the original runtime-setup increment. Current default checks and exact revision evidence are in [progress](../history/PROGRESS.md); current endpoint availability must be checked separately.

- Flutter analysis passed; 24 Flutter tests passed.
- Tests cover local models versus explicit downloads, incomplete/unsupported model files, repository URL validation, readiness-before-save, connection mismatch, narrow-screen layout and actual owned-process start/stop using a lightweight fixture.
- Two Python downloader tests passed with mocked Hub transfers; no large model was downloaded during development.
- The actual Swift preference migration function passed isolated checks for preserving newer values, selecting only Studio keys and rejecting corrupt input.
- macOS, Android debug and web compilation passed. The macOS landing FAB/setup page and existing Qwen runtime readiness were inspected.
- A full new multi-gigabyte remote model download and a new Qwen launch from the packaged UI have not been exercised end to end. Existing Qwen inference was previously verified; it remains available.

See [Hugging Face download documentation](https://huggingface.co/docs/huggingface_hub/guides/download) for snapshot downloads and revisions.


### Device availability inspection (F15)

**Inspect capabilities** now queries MLX Metal or Torch MPS availability through the chosen Python, after host/dependency checks. It imports only the device backend module, never model loaders or weights. The owned helper retains its ten-second deadline, bounded output and cleanup. Missing dependencies or unsupported hosts skip device imports; API/import failures show device availability as unverified with retry/environment guidance. A false API result shows unavailable without trying a fallback. Inspection preserves saved choices and any running model process.

The dependency-only CLI remains `--capabilities`; opt into device APIs with `--capabilities --probe-devices`. Legacy reports with unknown device availability remain valid. A detected device does not establish model loading, memory adequacy or successful inference. CPU/CUDA remain unavailable. Launch independently rechecks device availability.


Explicit **Inspect capabilities** also observes total host RAM and current free/reclaimable memory through the existing bounded read-only OS helpers. Unknown values remain visible on unsupported clients or probe failure; a memory-only failure preserves dependency/device results. Inspect again to refresh this transient snapshot. This is memory of the app host, not a remote runtime or GPU memory measurement, and does not assess selected-checkpoint fit or prove successful inference. No settings, weights or active runtime are changed.


## Experimental CPU implementation — issue #356

The Python bridge has an explicit testing path for unquantized local Qwen3.5
conditional-generation checkpoints. It is **experimental, with no verified real
CPU inference yet**, and is absent from normal managed setup/backend choices.
Auto/MLX/Torch-MPS selection and default capability reports are unchanged. CUDA
is unavailable. This is an implementation foundation, not F15 completion.

Use a separately owned process and unused loopback port for controlled testing;
keep the current runtime and saved app settings intact. The explicitly chosen
Python environment must already contain Torch and Transformers with
`Qwen3_5ForConditionalGeneration`. No packages or weights are downloaded by this
path. Safetensors must also be installed for CPU loading.

Before choosing a model, explicitly check the existing CPU loader APIs (issue #358):

```sh
python -B tools/qwen_backends.py --prepare cpu --experimental-cpu
```

This checks installed Torch, Transformers tokenizer/Qwen loader and safetensors
loader APIs without calling them. No helper target is required or created; no
packages are installed, model/tokenizer loaded, accelerator probed or thread
settings changed. Missing/broken dependencies fail without fallback. Successful
preparation only checks imports and API presence; compatible weights, memory,
actual inference and non-Apple host validation remain unverified. Run this in a
separately chosen, already provisioned environment; normal app setup still has no
CPU choice. Legacy preparation still requires its helper target and preserves
Auto/MLX/MPS behavior.

Capability discovery does not load weights:

```sh
python -B tools/qwen_server.py --backend cpu --experimental-cpu --capabilities
```

A future host validation can explicitly launch with compatible existing local
weights (quote paths with spaces):

```sh
python -B tools/qwen_server.py --backend cpu --experimental-cpu --cpu-threads 2 \
  --model "/path/to/existing/unquantized-checkpoint" --model-id cpu-validation --port 18765
```

CPU loading uses float32, an explicit CPU device context/tensor placement, eager
attention, safetensors only, `local_files_only=True` and
`trust_remote_code=False`. It does not require MLX, MPS, CUDA or Accelerate and
never automatically falls back. Thread limit is 1–32, default 2; this bounds
intra-op parallelism, not total memory or every native-library thread. Quantized
folders and unsupported architecture metadata are rejected before model load.
Experimental CPU startup bounds config metadata to 1 MiB and the safetensors
index to 8 MiB, reading at most each limit plus one byte before rejecting an
oversized file. Invalid UTF-8 and excessively nested JSON are rejected with a
sanitized checkpoint error before workers or model loaders start. Containment
and metadata checks are preflight, not a filesystem sandbox: files may change
before the trusted loader reads them. These bounds do not constrain tensor
allocations or establish model memory adequacy.

Float32 can require substantially more memory than stored weights: no model,
especially 9B, is certified adequate without measured live-host evidence.

The inherited HTTP limits apply: one request, 4096 input/output-token ceilings,
180-second generation deadline, streaming heartbeats and client-disconnect
cancellation. Checks run around preprocessing, each streamed fragment and token
stopping criteria. A native prefill/kernel cannot be interrupted mid-call;
terminating the separately owned test process is the hard-stop boundary. These
limits do not impose a model-loading deadline or memory quota. `/health` reports
`backend: torch`, `device: cpu` after a successful load, without certifying CPU
performance or acceptance. Existing app readers intentionally treat that device
as unknown until managed CPU integration is delivered.

Next implementation increments may add managed CPU setup, compatible
checkpoint budgeting and managed-host integration with honest unsupported states.
Non-Apple desktop real inference, restart/error/stop measurements, MLX regression
and separate CUDA-host evidence still gate their promised support claims. Do not
substitute injected tensor/model APIs, real HTTP fixture sockets or app builds
for those live measurements. See the canonical F15 ledger.

Reproduce the small real-library API fixture with an already compatible Python
environment (no dependency installation or downloads):

```sh
ASG_CPU_API_FIXTURE=1 python -B tools/test_qwen_backends.py CPUAPIFixtureTests
```

It constructs and deletes a tiny random local checkpoint and tokenizer, verifies
CPU/float32 placement and streams two generated tokens. This is library API
coverage, not pretrained-model correctness, performance or F15 live acceptance.
