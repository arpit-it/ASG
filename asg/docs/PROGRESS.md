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

## Transactional storage — issue #4

Implemented cross-platform transactional repositories and atomic legacy migration without deleting preferences. Durable prototype interactions preserve tasks/completion, counters and notes across restart. Save failures keep committed records and expose retry; rapid saves serialize and chat waits for persistence. Fixed review-discovered kind-change note loss and focused-input loss during generation. Navigation guards prevent switching projects during unsaved changes. Added migration/rollback/corruption/restart/write-failure, interaction/concurrency/navigation and actual Chrome IndexedDB tests. Final PR records validation and independent review.

Validation: formatter/analyzer passed; 63 regular Flutter tests passed (live inference skipped by default); actual Chrome IndexedDB test passed; Python download fixtures 2/2 and HTTP/SSE fixtures 4/4 passed. macOS debug, Android debug and web builds passed. Strict corruption and all review-discovered interaction races have regression coverage.
The opt-in real local Qwen custom-edit test also passed after the storage changes. It used the already running MLX runtime; no model download or runtime replacement occurred.

## Repository safeguards — issue #8

Storage PR #9 independently reviewed/merged as 2b6602a with all checks passing. Configured and re-opened GitHub main protection: required PRs, both CI jobs from GitHub Actions, current branch and resolved conversations, including admins; blocked force pushes/deletion. Saved approval for every external fork workflow and scoped allowed Actions to owner/GitHub plus pinned Flutter action. Verified read-only token default, disabled Actions approvals, no invited collaborators and unchanged public visibility. Enabled private vulnerability reporting. Added CODEOWNERS, contributing/security policies and agent instructions. Formal GitHub second-account approvals remain unavailable with the sole owner identity; agent review remains independently required by workflow.

## Independent Flutter generation — issue #3

Implemented the explicitly approved fixed Flutter web MVC template and portable requirements/application JSON, new canonical destination creation, bounded offline command helper, durable step outcomes/exceptions, unchanged-input recovery and an owned local preview of the actual compiled output. Early review found lifecycle leaks, unchecked resolution metadata and transient thrown failures; all fixed with regression tests. Actual fresh generated projects passed analysis, independent widget tests and web builds. App regression suite, Chrome storage and subprocess fixtures passed; main app macOS/Android/web builds passed. Final PR records exact verification/review/merge evidence. See GENERATION.md for limitations.

Browser verification rendered the actual compiled generated app in Chrome, increased its counter (3 → 4) and toggled a task; no browser console errors appeared. Fixed a legitimate cross-site top-level navigation rejection and a macOS empty process-group cleanup edge case discovered during real verification. Screenshot: /private/tmp/asg-generated-preview.jpg (local QA artifact, not a bundled asset).

Final local checks: formatter/analyzer passed; 78 default Flutter tests passed (Qwen and real generation skipped by default), actual Chrome IndexedDB test passed, and the opt-in real generated-project analysis/widget-test/web-build/HTTP preview test passed. Python generation fixtures 4/4, downloader 2/2 and HTTP/SSE 4/4 passed; Swift migration fixtures passed. macOS debug, Android debug and web app builds passed. Existing Qwen MLX /health remains ready/idle; no model or runtime replacement occurred.

Issue #3 implementation is tracked by [PR #11](https://github.com/arpit-it/ASG/pull/11) on codex/3-flutter-generation. Its final exact-revision independent review, CI results and merge commit are the authoritative delivery evidence; inspect that PR before starting a later increment. Local validation and feature boundaries are recorded in GENERATION.md / PROGRESS.md.

## Generated snapshot identity — issue #12

Source generation #3 is complete via reviewer-merged PR #11 (979dc4f2). Added a shared stable v1 input serializer and derived current/earlier/unknown saved-snapshot status. The generation page now warns when later prototype/requirements changes are absent from a saved build, while clearly labeled earlier-build preview remains available. No stored record fields, approvals or filesystem guards changed. Frozen legacy fingerprints and state/requirements/UI/reopen regressions cover compatibility. Real generated-project verification caught lost JSON imports during extraction; restored imports and retested. Final PR records test/build and independent review evidence.

Local validation: formatter/analyzer passed, 86 default Flutter tests passed (live Qwen/generation skipped by default), and the explicit real independent-project resolve/analyze/test/web-build/HTTP-preview test passed. macOS debug, Android debug and web builds passed. Existing Qwen runtime remained ready/idle. Frozen v1 fingerprints confirm no history migration is required.

Issue #12 delivery is tracked by [PR #13](https://github.com/arpit-it/ASG/pull/13), branch codex/12-generated-snapshot-status. Its final exact-revision review, required CI and merge record are the authoritative completion evidence; inspect the PR before starting the next increment.

## Project selection ordering — issue #14

Branch `codex/14-session-selection` fixes an observed race: project selection previously left the session idle while its selection record was saving, allowing overlapping selection/creation. Both actions now share a busy guard; successful UI selection waits for persistence, failures preserve the current project and allow retry. Disposed sessions reject new work and ignore delayed results; creation stops before a follow-up selection write if disposed. Home navigation, pointer interaction and keyboard focus are blocked during session writes to avoid editing a workspace being replaced. Existing storage records are unchanged.

Added six deterministic delayed-write controller tests and a navigation/interaction-lock widget regression. Final local checks and independent review/CI evidence are recorded in the issue-linked PR. Existing Qwen MLX health reported ready/idle; this is a health check, not a new live inference verification. Unrelated tracked IDE changes are preserved.

Issue #14 delivery: [PR #15](https://github.com/arpit-it/ASG/pull/15), branch `codex/14-session-selection`. Local formatter/analyzer, 93 default tests (two opt-in tests skipped) and web build passed. Final exact-head independent review, required CI results and merge SHA are authoritative in that PR.

## Editable project details — issue #16

Branch `codex/16-edit-project-details` adds a workspace dialog for editing a project's name and requirements. Pure shared name validation, a dedicated controller and metadata service preserve MVC. The service checks missing/duplicate/stale records, freezes a never-saved starter before changing its metadata inputs, then rereads current records and saves metadata before the controller publishes success. Existing application records, chat, revision, interactions, identity, type/platforms/location and unrelated projects are preserved. The view retains input on failure and disables save/close while writing; workspace pending/busy state gates entry. The header refreshes without remounting the running app. Source generation already fingerprints requirements, so earlier exports become outdated and future exports use the updated metadata.

Fourteen new editor/controller/service/widget tests cover restart preservation, durable write ordering/failures/retry, validation, stale/missing/duplicate/corrupt records, unrelated records, concurrent/disposed saves, session refresh and entry guards. Existing session navigation test now also checks editor gating. No schema changes, generated-folder overwrites or automatic app regeneration. Final PR records validation, independent exact-head review, CI and merge evidence.

Issue #16 local validation: formatter/analyzer passed; 107 default Flutter tests passed, with live Qwen and real generation skipped by default. Web and macOS debug builds passed. Existing Qwen /health was ready/idle; no fresh live inference is claimed for this metadata-only workflow.

Issue #16 delivery: [PR #17](https://github.com/arpit-it/ASG/pull/17), branch `codex/16-edit-project-details`. Local formatter/analyzer, 107 default tests and web/macOS debug builds passed. Final exact-head independent review, required CI and merge SHA are authoritative in that PR.

## Dashboard generation outcomes — issue #18

Branch `codex/18-dashboard-build-status` replaces unconditional “No builds yet” and disconnected-generation placeholders with typed summaries of actual saved generation records. Cards distinguish absent, generated/unverified, unfinished, saved successful verification, failed and unreadable outcomes; input fingerprints show current/earlier/unknown app and requirements. Strict existing record validation gates saved success. Corrupt history is isolated per project; corrupt application data preserves build evidence with unknown input match. No records, files, commands or live processes are changed by summary reads. Returning from a standalone project refreshes status.

Nine dashboard regressions cover all saved phases/reopening, no writes, requirements/interaction staleness, unknown/corrupt/invalid success records, mixed-project search/open, return-navigation refresh and narrow layout with enlarged text. Only latest saved evidence is available; no current artifact integrity, live preview or full last-successful-build history is claimed. Final linked PR records tests, independent review, CI and merge evidence.

Issue #18 local validation: formatter/analyzer passed, 115 default Flutter tests passed (live Qwen and real generation skipped by default), and web build passed. Existing Qwen health reported ready/idle; no fresh inference is claimed for dashboard status reads.

Issue #18 delivery: [PR #19](https://github.com/arpit-it/ASG/pull/19), branch `codex/18-dashboard-build-status`. Local formatter/analyzer, 115 default tests and web build passed. Final exact-head independent review, required CI results and merge SHA are authoritative in that PR.

Independent review identified that production startup validation blocked the dashboard before its per-project summary errors could be shown. Fixed post-migration snapshot loading to retain unreadable application/generation values verbatim, surface per-key FormatExceptions and allow unrelated records to load. Initial migration, global records, physical database corruption and all writes remain strictly validated. Real native file close/reopen + dashboard regression verifies unchanged raw records and access to healthy projects; actual Chrome IndexedDB reopen covers both damaged namespaces. Added strict global-corruption regression and retained legacy migration/physical-corruption tests. Fresh exact-head review is required for this correction.

Issue #18 corrected-revision validation: formatter/analyzer, 117 default Flutter tests, actual Chrome IndexedDB test, web build and macOS debug build passed. PR #19 must receive fresh exact-head review and required CI after the production-storage correction; default-skipped Qwen/generation are not fresh live verification.


Issue #18 completed through independent reviewer-merged PR #19 as 2fce778be8e3fb29495c87b43f0707001394ee2f. Final corrected head fd417afd was approved; both required CI jobs passed, including actual Chrome IndexedDB and generated-project verification. Issue closed and main synchronized; unrelated tracked IDE edits remain preserved.

Issue #20 (`codex/20-creation-recovery`) repairs partial creation: after project persistence succeeds but session selection fails, show a saved-but-not-opened explanation and an explicit selection-only retry. Duplicate IDs are rejected before writing. Retry rereads canonical metadata, retains the previous workspace until selection commits and rejects missing/ambiguous records. Busy/disposal guards remain; opening an existing project dismisses recovery. No rollback, schema change or saved-project deletion. Six new controller/widget regressions cover write failures, repeated retries, stale metadata, duplicate IDs, missing/ambiguous records, disposal, overlap and the wizard-to-retry flow.

Issue #20 validation: formatter/analyzer, 123 default Flutter tests (live Qwen and real generation skipped), and web build passed. Existing MLX runtime health is ready/idle; no fresh inference claim. Final linked PR supplies independent exact-head review, required CI and merge evidence.


Issue #22 (`codex/22-discussion-plan-mode`) adds the documented conversational Plan mode beside Discuss, reached through the workspace's Discuss and plan action. Both modes have no file/command/application-edit tools. Plan prompts request requirements, feasibility/dependencies, tasks, acceptance criteria, risks and review/approval; persisted v1 content is visibly labeled as an unapproved draft. Reopening defaults to Discuss while retaining history; no schema migration or executable approved-plan engine is implied. Mode changes and duplicate sends are blocked during requests. Cancellation before the initial save completes prevents inference; partial/empty/failed replies never publish a plan. Nine deterministic controller/widget/native-reopen regressions cover persistence failures, cancellation/disposal, history, no application writes and workspace navigation.

Issue #22 local validation: analyzer, 132 default Flutter tests (three opt-in tests skipped), web build and the explicit real local Qwen planning test passed. Real planning streamed multiple chunks and persisted the labeled draft using the existing MLX runtime; this verifies the bounded conversation flow, not arbitrary implementation. The linked PR will carry exact-revision independent review, required CI and merge evidence.

Issue #22 additional validation: formatter passed with no changes; macOS debug build passed and the existing opt-in real Qwen instruction test passed, confirming a custom instruction still streams, saves a revision and refreshes the prototype. The stable installed app was not replaced.
