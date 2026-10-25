# Technical Decisions

Flutter replaces SwiftUI at the user’s explicit request. Use platform plugins for folder selection and small local records. Versioned JSON preferences keep the initial increment small; migrate to SQLite before execution history or large conversations. No model checkpoint or inference runtime is bundled or verified. Runtime licensing and memory benchmarks are gates for milestone 2.

## Runtime setup — 25 October 2026

Add a top-right landing FAB and a dedicated MVC setup screen. Support complete downloaded local checkpoints first; explicit HF/Git downloads create new folders and run no repository Python. Initial managed backend is the existing Qwen3.5 Transformers bridge on Apple Metal. Bundled scripts are app assets; Python selection and repository/model paths are configuration.

The user explicitly approved disabling App Sandbox for this macOS build after automatic review rejected the initial entitlement expansion. Retain honest host-permission semantics; do not claim Python process isolation. Preserve existing sandboxed preferences before Flutter startup. Other platforms connect to the host runtime and display an unsupported-managed-setup explanation. Stop only an app-owned process. A signed helper and more checkpoint backends remain future architecture work.

## App-led workflow and live prototype — 25 October 2026

Make the user supply intent/choices while Studio leads creation. Restore the current project directly into a chat-left/preview-right workspace. Use a bounded interpreted application schema for the first working edit loop: actual Flutter controls execute validated definitions without arbitrary source execution. Common exact instructions have a deterministic fast path; other requests use compact Qwen edits. Publish new revisions only after successful validation and persistence. This is a scoped prototype runtime, not the deferred arbitrary-code generator/build engine. See LIVE_WORKSPACE.md.


## Verified MLX streaming runtime — 25 October 2026

Use the existing Qwen3.5-9B weights converted locally to 4-bit MLX for the active Apple Silicon runtime. The full BF16 Torch path previously timed out on structured edits; the MLX path passes the actual custom-edit integration test with streamed phases/summary chunks. Preserve the existing API endpoint/model ID and original weights. Keep Python dependencies isolated/pinned and model caches ignored. Use SSE with heartbeats, explicit completion/error semantics, inactivity/total limits and cancellation. Show processing state and human-readable summary text; never apply an incomplete or unvalidated edit. Details and measurements: QWEN_STREAMING.md.

## Issue #4: transactional repositories

Use Sembast 3.9.0 on native files and sembast_web 2.4.6+1 on IndexedDB behind RecordStorage. This provides transactions on all Flutter targets without a native SQLite/WASM provisioning step. Preserve v1 key payloads and migrate validated records plus completion marker atomically, retaining preferences. Use strict database open to surface corruption rather than reset. Session snapshots preserve synchronous repository reads; concurrent native processes and live multi-tab UI synchronization are outside this increment. See STORAGE.md.
