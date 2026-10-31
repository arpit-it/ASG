# Coding model discovery on macOS

Runtime setup → **Browse coding models for this computer** opens the F22 discovery
milestone. It starts with eight coding/general-engineering MLX 4-bit candidates:
Qwen3.5 9B/27B, Qwen3.8 27B, Qwen2.5 Coder 7B/14B/32B,
Qwen3 Coder 30B A3B and Devstral Small 2507. This is not an exhaustive catalog or
an inference certification. Explicit Hugging Face search adds up to 40 matching
`mlx-community` repositories per query; other formats/publishers remain available
through the existing custom repository form, subject to runtime validation.

The native service detects Apple Silicon, total unified memory and an OS estimate
of free/reclaimable pages. Unknown hardware stays unknown. Each source check reads
public metadata and pinned configuration/index JSON only: no model weights,
credentials, prompts, project data or private paths are sent. Sizes sum actual
artifact file sizes at the returned immutable revision, not total repository
history storage. Missing sizes/configuration/tokenizer/weights/indexed shards,
malformed metadata and offline/access failures cannot enable selection. Search
and refresh errors preserve working model settings and existing files.

Hardware estimates count **all resident weights**, including MoE experts, plus
25% overhead and 4 GiB runtime/cache allowance; another 6 GiB is reserved for the
OS/apps. They assume bounded context and do not prove loadability, speed, coding
quality, structured edit compatibility or cancellation. Current memory pressure
is separate from total-memory fit. These estimates are intentionally conservative
heuristics; workload-dependent peaks and disk capacity still need checking.

Only the existing ASG-managed `Qwen3_5ForConditionalGeneration` architecture with
4-bit MLX metadata can be handed to the download form on Apple Silicon. Other
coding architectures may fit the Mac but remain disabled in ASG pending their
runtime adapters. Metadata never produces a Verified inference label. F15 owns
additional backends; F17 owns real evidence and F22 remains incomplete.

**Use in download form** copies only the repository and exact revision. It does
not download, persist model settings, switch the runtime, install dependencies or
start inference. Review the selected source/license, destination and existing
MLX Python environment, then separately press **Download model & validate**.
Existing folders are never replaced. GitHub project/reference links are shown
separately: a README/license-only repository is not a checkpoint.

Validation: `flutter test test/model_catalog_test.dart` covers HTTP validation,
revision/license changes, estimates, unsupported/unknown hosts, retry, busy and
disposal behavior, responsive UI and selection without downloads/settings writes.
Explicit `dart run tools/check_model_catalog.dart` performs public metadata and
native hardware checks only; it does not fetch weights or run inference.

The native macOS memory inspection runs fixed read-only `sysctl` and `vm_stat` helpers with a three-second deadline per helper and a combined 64 KiB stdout/stderr limit. On timeout or excess output, ASG terminates and awaits the owned helper (up to two additional seconds for cleanup); stderr is discarded. A failed headroom probe retains detected total RAM with unknown headroom. These OS observations are estimates, never successful model loading or inference evidence. The helper owns only the fixed process; it is not a process-tree execution sandbox.


## Preferred choices (issue #348)

The default picker shows one curated model covering Ask, planning, coding and
review, rather than every size variant or public search result. Press **Check
preferred models** to validate public metadata for Qwen3.5 27B and 9B. The policy
prioritizes 27B only when its supported 4-bit MLX metadata, total memory budget
and current available-memory estimate pass; otherwise it considers 9B. The
same model serves all four roles; ASG does not claim specialized measured winners
for each role. Unknown memory, current pressure, unsupported hosts, failed
checks and arbitrary discovery results never become preferred recommendations.
Reopen the page to refresh hardware estimates after freeing memory.

This ordering is an explicit curation policy, not a throughput benchmark or
inference certification. Upstream capability evidence is available at
https://github.com/QwenLM/Qwen3.5; larger/newer and specialist models remain
excluded from preferred choices until their architecture and application behavior
are supported. No model is promised to run on every device: managed loading here
still requires Apple Silicon macOS. Other ASG platforms use compatible runtime
connections. Turn off **Preferred models only** for existing advanced discovery
and manual source inspection. No model is downloaded or switched by checks.
