# Technical Decisions

ASG is a Flutter application targeting Android, iOS, web, macOS, Windows and Linux. Included platform runners do not establish tested device support. Managed MLX setup and the current independent Flutter web generator host are macOS-specific; other platforms retain supported app features and runtime connection controls.

Flutter supersedes the original SwiftUI/macOS-only product framework. Historical decisions below retain provenance; later Sembast and MLX decisions supersede preference-only storage and BF16 runtime choices. Model files/environments remain external; prior MLX benchmarks are recorded observations, not current runtime health.

## Runtime setup — 25 October 2026

Add a top-right landing FAB and a dedicated MVC setup screen. Support complete downloaded local checkpoints first; explicit HF/Git downloads create new folders and run no repository Python. Initial managed backend is the existing Qwen3.5 Transformers bridge on Apple Metal. Bundled scripts are app assets; Python selection and repository/model paths are configuration.

The user explicitly approved disabling App Sandbox for this macOS build after automatic review rejected the initial entitlement expansion. Retain honest host-permission semantics; do not claim Python process isolation. Preserve existing sandboxed preferences before Flutter startup. Other platforms connect to the host runtime and display an unsupported-managed-setup explanation. Stop only an app-owned process. A signed helper and more checkpoint backends remain future architecture work.

## App-led workflow and live prototype — 25 October 2026

Make the user supply intent/choices while Studio leads creation. Restore the current project directly into a chat-left/preview-right workspace. Use a bounded interpreted application schema for the first working edit loop: actual Flutter controls execute validated definitions without arbitrary source execution. Common exact instructions have a deterministic fast path; other requests use compact Qwen edits. Publish new revisions only after successful validation and persistence. This is a scoped prototype runtime, not the deferred arbitrary-code generator/build engine. See LIVE_WORKSPACE.md.


## Verified MLX streaming runtime — 25 October 2026

Use the existing Qwen3.5-9B weights converted locally to 4-bit MLX for the active Apple Silicon runtime. The full BF16 Torch path previously timed out on structured edits; the MLX path passes the actual custom-edit integration test with streamed phases/summary chunks. Preserve the existing API endpoint/model ID and original weights. Keep Python dependencies isolated/pinned and model caches ignored. Use SSE with heartbeats, explicit completion/error semantics, inactivity/total limits and cancellation. Show processing state and human-readable summary text; never apply an incomplete or unvalidated edit. Details and measurements: QWEN_STREAMING.md.

## Issue #4: transactional repositories

Use Sembast 3.9.0 on native files and sembast_web 2.4.6+1 on IndexedDB behind RecordStorage. This provides transactions on all Flutter targets without a native SQLite/WASM provisioning step. Preserve v1 key payloads and migrate validated records plus completion marker atomically, retaining preferences. Use strict database open to surface corruption rather than reset. Session snapshots preserve synchronous repository reads; concurrent native processes and live multi-tab UI synchronization are outside this increment. See STORAGE.md.

## Issue #3: trusted Flutter web template

Generate one fixed MVC template with validated application/requirements JSON as data, then execute only approved offline Flutter operations through a bounded Python process-group helper. Preserve new-directory exclusivity and source/resolution/output fingerprints. Persist real outcomes and exceptions transactionally. Serve verified web output through an owned token-scoped loopback server, opened explicitly in the browser. This is a macOS-hosted export/verification slice, not arbitrary LLM code execution, native generation, continuous source editing, external deployment or a security sandbox. See GENERATION.md.

## F01/F02 structured planning and approval — 25 October 2026

Persist a typed requirements/task board with revision-based approval invalidation. Treat model-proposed general tasks as queued planning data requiring explicit additive import. Execute only the versioned allowlisted fixed Flutter starter graph, with saved task results and exact Plan approval provenance. Issue #50 extends context to prototype definition/revision and checks captured Build inputs before host work. Preserve legacy readability while requiring fresh drafts, without inventing consent or migrating old prose into executable tasks.


## 26 October 2026 — confined candidates and pointer promotion (F04)

Keep initial creation as a trusted fixed Flutter web starter. Apply approved-task Dart proposals only into separate new candidates after full-file diff review. Run candidate tools through macOS Seatbelt with fixed operations, bounded process groups, isolated environment and candidate/temp writes; keep shared SDK/packages read-only. Never fall back to host-permission execution when confinement is unavailable. Retain exact approval/task/source/input evidence and distinct durable candidate checkpoints. Avoid filesystem swaps: validate a second preview first, then atomically compare expected records and switch the saved working pointer with a previous-working backup. Transfer preview-host ownership only after commit. This preserves the working source/server on preparation, command, preview or storage failure. The publication commit is noncancellable; general sandboxing, rollback/history, repairs and other adapters keep their own requirements.
