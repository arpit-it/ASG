# Progress — 25 October 2026

## Environment / milestone 0

Empty starting repository. Flutter 3.47.6 / Dart 3.13.5, macOS 27.0.1, Xcode 27.0, Git 2.54.0, Python 3.12.8 available. Android SDK exists but command-line tools are missing and license status is unresolved. Windows/Linux host builds unavailable on macOS. Local model/runtime compatibility and memory benchmarks are deferred; no model has been downloaded or selected.

## Original directory foundation / historical milestone 1 increment

Created Flutter runners for Android, iOS, web, macOS, Windows, Linux. Implemented dashboard, search, validated project creation, persistent versioned project records, supported native folder selection, metadata workspace, configuration status, model provider interface, and an approval policy with three-repair limit. Display name: Automated Software Generator.

Validation: static analysis passed; three automated tests passed (persistence, approval policy, project creation/validation/search). Release web build passed, including compiler Wasm dry run. macOS first build compiled but signing failed due to bundle extended attributes; the normal Flutter build retry also hit signing attributes. Copying the compiled bundle to `/private/tmp/automated-software-generator-preview/Automated Software Generator.app` with `ditto --noextattr --norsrc`, then ad-hoc signing succeeded and Launch Services accepted the launch. This workaround does not establish a clean standard macOS build. iOS, Android, Windows, and Linux builds unverified. Real picker/restart/device acceptance remains manual.

Original milestone 1 is partial: existing-repository import and editable settings are deferred. UI modes do not implement conversation or approval. No real inference, source generator, tool execution, build orchestration, preview, or self-development is implemented. No generated project build/test success is fabricated.

Next: complete settings/import, migrate storage to transactional records, verify a compatible local runtime and checkpoint/license, then implement persisted Discuss/Plan and explicit plan approval before adding execution.

## Original directory Android Studio run/debug setup (historical)

Added a version-controlled `.run/Automated Software Generator.run.xml` Flutter configuration targeting `lib/main.dart`, usable for both Run and Debug with an IDE-selected device. Added `docs/ANDROID_STUDIO.md` and README setup instructions. Configuration XML/entry point validated. Android build and launch remain unverified: command-line tools are missing and SDK licenses require user review.

## ASG repository migration and Qwen — 25 October 2026

Active Git repository: `/Users/arpitsinha/AndroidStudioProjects/ASG`; Flutter root: `asg/`. Replaced only the initial starter app and related configuration, preserving package `asg`, existing platform identifiers, Git history, and repository layout. Added shared run configurations for opening either repository root or Flutter root.

Added persisted local-model configuration, real connection test, and per-project saved Discuss chat. Qwen3.5-9B was found in `/Users/arpitsinha/ARG-model-downloads/qwen3.5-9b` and loaded on Apple Metal using existing Torch/Transformers plus a project-local Accelerate helper. Real inference returned `Ready to plan software.` in 15.64 seconds. No model download or system-wide package install occurred. See LOCAL_QWEN.md for limits and restart instructions.

Final static analysis passed and migrated web build passed with Qwen chat. Android APK build passed after the Gradle distribution was downloaded through curl and verified against its official SHA-256. APK: `build/app/outputs/flutter-apk/app-debug.apk`. Android device launch remains unverified. macOS build from this migrated directory passed with normal signing, and the app was launched and confirmed running. All eight Flutter tests passed, including restored project conversation history. Local model health and local/remote browser-origin checks passed.


## MVC refactor and coding standards — 25 October 2026

Split the app into typed models, focused views, feature controllers and storage/platform/HTTP services. Added controllers for dashboard, project creation, workspace, chat and model settings; moved chat/configuration persistence out of views. Preserved preference keys and JSON shapes. Validation now rejects path separators and control characters while accepting ordinary project names.

Verified after refactor: static analysis passed, all 14 tests passed, Android debug APK built, and web build passed. Added controller tests for failed saves, chat persistence/failures/disposal, wizard validation, plus architecture boundary checks. No fresh macOS build/device acceptance is claimed for this refactor.

Created CODING_STANDARDS.md as the canonical project instruction document and linked it from root AGENTS.md and the application README. It captures MVC, Effective Dart, async lifecycle, integration, responsive UI, safety, tests and honest completion reporting. The standards distinguish current enforcement from follow-up audit work.

## Landing runtime setup — 25 October 2026

Added upper-right runtime FAB, live runtime health, local repository/model-folder scanning, compatible-checkpoint selection, explicit HF/HTTPS Git model download, Python helper preparation, managed process start/stop, and readiness-gated chat configuration. Added a cross-platform connection fallback and setup logs. Existing runtime and metadata keys remain intact; new setup data uses `studio.runtimeSetup.v1`.

The user approved the app-specific macOS sandbox entitlement change needed for chosen host-runtime integration. Added migration of missing Studio preferences from the old app container, preserving newer values. App/child process isolation is not claimed. See RUNTIME_SETUP.md for supported models, ownership, requirements and limitations.

Validation: 24 Flutter tests, 2 mocked Python download tests, actual Swift preference-migration fixture checks, static analysis, macOS build, Android debug APK build, and web build passed. Inspected the landing FAB/setup UI and confirmed existing Qwen runtime health. Full remote weight transfer and a new large-model launch from the packaged page remain unverified; no large model download was performed.

## App-led creation, default workspace and live instruction loop — 25 October 2026

Replaced the technical-first form with idea → suggested experience/features → review. Studio derives Flutter/platform metadata and creates the saved project from selected choices. The default window restores the current project with chat on the left and a functional interpreted prototype on the right; phone tabs retain both panes. Projects/new-project/runtime actions remain accessible.

Added validated AppDefinition/AppElement models, actual interactive Flutter controls, compact model-edit operations, supported local instruction handling, saved application revisions and conversation history. Successful edits persist before publication and refresh the visible preview/version immediately. Unknown operations, invalid targets, bad JSON, timeouts and failed writes preserve the last working version. Current interactive values are included in subsequent instructions. No arbitrary source generator or external build/preview is claimed.

Validation: 40 deterministic/controller/widget tests passed; the live inference test is skipped by default. Static analysis passed. Verified the desktop layout with the existing saved project and its interactive preview. Final macOS, Android debug APK and web builds all passed from the compact-edit source. The default workspace was launched and visually verified with the existing saved project.

The opt-in real Qwen edit check timed out twice at the 120-second client limit, including after compacting the update protocol. It did not apply or persist a failed response. The test model process was reset after timeout. The earlier short-text inference success does not establish acceptable structured-edit latency. Fully recognized edits such as `add a counter and change the theme to green` work immediately without inference and have a widget-level submit/save/refresh test. Other custom edits remain dependent on resolving local runtime performance. See LIVE_WORKSPACE.md for scope and limits.


## Qwen timeout fix, streaming and hourly development — 25 October 2026

Created the active hourly thread schedule `develop-automated-software-generator` and durable AGENT_MEMORY.md plus MASTER_REQUIREMENTS.md. Verified the existing origin is https://github.com/arpit-it/ASG.git and remote main matches the initial local commit. No push was requested or performed.

Replaced the active 19 GB Torch BF16 runtime with a locally converted 4-bit MLX Qwen3.5-9B copy (originals preserved, no model download). Short structured benchmark: 2.59s load, 5.89s total, 67.8 generation tokens/s, 5.29 GB peak. The previously failing real custom edit integration now passes, including saved revision and streamed summary/phase assertions with built-in edits disabled.

Added SSE status/token/heartbeat/completion/error transport, bounded inactivity and total time, stream cancellation and single-worker inference. Chat shows persistent thinking/writing/checking/applying loaders and incremental response text, and applies only a complete validated saved update. The normal Discuss screen also streams. Runtime preparation recognizes MLX.

Checks passed: analysis, 48 regular Flutter tests, one opt-in live local-Qwen integration test and 4 actual HTTP/SSE handler tests with a lightweight backend. macOS, Android debug APK and web builds all passed. The real streamed custom-edit test also passed again against the restarted final bridge. See QWEN_STREAMING.md for current runtime instructions and limits.

## CI and GitHub delivery — issue #2

Published the independently reviewed baseline to main as 3dc6142 (issue #1). Added least-privilege CI for formatting, analysis, Flutter tests/web build and Python HTTP/download fixtures, with pinned actions and bounded job timeouts. Added focused bug/feature issue forms and a PR template. Real local Qwen tests remain opt-in. Review and remote CI results are tracked by the issue #2 PR.

## README alignment — issue #6

PR #5 was independently reviewed and merged as 2bad70a after both CI jobs passed. Updated the root/application READMEs to explain the app-led product goal, working prototype and streamed local runtime, future generation/build features, platform limits, MVC, setup, validation and contribution workflow. Verified relative documentation links and diff formatting. No production code changed.
