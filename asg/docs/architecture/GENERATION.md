# Independent Flutter source generation

## Current slice

ASG is a Flutter application targeting Android, iOS, web, macOS, Windows and Linux. Included platform runners do not establish tested device support. Managed MLX setup and the current independent Flutter web generator host are macOS-specific; other platforms retain supported app features and runtime connection controls.

Before opening generation, use Discuss, Plan and Review to save a current Plan explicitly scoped to the fixed starter. Inspect its validated four-task preview and approve it. Build rereads this exact approval against current project metadata, requirements-board revision and prototype revision/definition; stale, withdrawn, unapproved, legacy or malformed contracts cannot start. The generation form then requires separate operation consent. Approval does not authorize arbitrary source edits.

On macOS, open a saved project's preview and choose **Generate Flutter source** (code icon). Review the current requirements/prototype, choose an existing parent directory, a new lowercase folder name, an initialized Flutter SDK directory and an installed Python 3 executable. Explicitly approve the listed operations, then choose **Generate, test and build**.

The generator writes a fixed, portable Flutter web MVC starter: typed model, observable controller, view, bootstrap, independent tests, JSON application data and requirements metadata. User/model text is serialized only into JSON data, never executable Dart/HTML or dependency declarations. It supports the existing headings, text, tasks/completion, counters, notes and bounded button actions. It does not synthesize arbitrary model-written code or generate other frameworks/native runners yet.

Saved generation outcomes now identify whether their recorded application/project inputs match the current screen, represent an earlier snapshot, or cannot be identified. Earlier/unknown builds have explicit preview/open labels. This compares recorded input fingerprints; source/output integrity is still checked separately before preview. Later chat or interaction edits require a new folder to export, while an earlier verified build remains available for explicit preview. Existing v1 history stays readable without migration.

The default chat/right-hand preview remains ASG's interpreted prototype. Generated source is a separate snapshot; later chat edits require generation into another new folder. Existing projects are never regenerated in place or overwritten. Generated-app interactions are session-only; ASG's own prototype remains durable.

## Verification and preview

Only these fixed operations run, with argument arrays and no shell command interpolation:

1. flutter --no-version-check pub get --offline
2. flutter --no-version-check analyze --no-pub
3. flutter --no-version-check test --no-pub
4. flutter --no-version-check build web --no-pub --no-web-resources-cdn

Each operation has a 180-second deadline and a 64 KiB combined stdout/stderr byte limit. Output beyond that limit terminates the owned process group and records `outputLimitExceeded`, even if the command already exited zero; exactly 64 KiB is permitted. Captured diagnostics remain bounded. This outcome blocks subsequent operations and cannot yield Ready. The trusted Python helper starts an owned process group, terminates it on timeout/parent exit/disposal, and escalates termination when needed. A macOS empty-group permission response after root exit is not treated as a failed Flutter command; live-root termination failures still surface. This is lifecycle management, not an OS security sandbox.

The SDK must already have its tools snapshot, Dart executable and package configuration. Offline resolution uses existing pub-cache packages. Analytics/version checks are disabled and Flutter's artifact-download base points to an unavailable loopback mirror so missing SDK artifacts fail rather than silently downloading. There is no network isolation guarantee: the selected installed SDK/Python and local caches are trusted host tools. No system software, model weights or third-party application package is installed by this flow.

Only a successful analyze/test/build can produce a ready result. **Start actual built preview** serves the fingerprinted web build on loopback with a fresh unpredictable URL prefix, no directory listing/source serving and cross-origin asset restrictions. **Open generated app in browser** opens that local URL explicitly. Closing the setup screen stops its owned server. Opening a browser URL alone is not proof that all application behaviors work.

## Boundaries and recovery

Parent/SDK paths are canonicalized, symbolic-link aliases rejected, and a single new directory is created exclusively. Template files use exclusive creation. Source files and generated output are fingerprinted. Verification checks source before stages; dependency lock/package configuration/graph fingerprints are captured after resolution and checked before later commands and retries. Source or critical metadata changes stop verification instead of executing changed inputs. Output changes prevent/reject preview serving.

Outcomes, step exit codes/output and failures are stored transactionally under studio.generation.v1.<projectId>. Exceptions after preparation persist a failed outcome; failed history writes preserve previous durable history. On reopening, interrupted verification is displayed honestly. Retry runs the saved verification sequence on unchanged source and metadata; corrected SDK/Python selections can be explicitly supplied. An interrupted resolution without a durable metadata snapshot requires a new folder. Partial generation folders are retained; generation failure never silently deletes/replaces them. No automatic source repair is attempted.

Build/.dart_tool caches are generated tool-owned data, not a security boundary. These checks do not defend against a malicious same-user host racing filesystem changes, modifying the installed SDK/Python/pub cache or database, or tampering with compiler internals. Do not use this feature to execute arbitrary downloaded/untrusted projects. Native concurrent app processes are outside the storage contract. The installed stable ASG app is not replaced.

## Validation

Native-host tests run on macOS/Linux; unsupported hosts retain controller/fallback tests and do not claim local generation support. Regular tests cover traversal/existing paths/symlinks/concurrent entries, hostile text as data, failed verification/retry, changed dependency metadata/output, preview scope, approval, duplicate submission, disposal, late server cleanup, durable exception recovery and UI outcome states. Python fixtures cover bounded output, nonzero exits, process-group timeout/descendant cleanup and macOS exited-group behavior.

The opt-in real test creates a new temporary project, runs actual offline resolution, analysis, generated widget tests and a web build, then checks served compiled output:

```sh
ASG_FLUTTER_SDK=/path/to/flutter flutter test test/source_generation_test.dart --dart-define=ASG_REAL_GENERATION=true --plain-name 'real independent generated Flutter project'
python3 -B tools/test_generation_command.py
```

CI runs the real generation test after warming the SDK/cache with the main app's checks/web build. The Qwen inference test remains separately opt-in; generation uses the current validated definition and does not invoke the model.

## Editing project requirements

The workspace's **Edit project details** action updates the saved name and requirements for future exports. It preserves project identity, platform/type/location and the current prototype/chat/revision. A starter that has never been saved is persisted before metadata changes, so restarting does not regenerate it from revised requirements. Failed writes retain input for retry; stale, missing or duplicated project records require reopening details. Existing exports remain immutable and compare as outdated when their requirements fingerprint differs. Change the actual prototype through chat, then export into a new folder.

## Dashboard outcomes

Project cards read the latest saved generation record and show no snapshot, unverified source, unfinished verification, saved verification success, failure or unreadable history. Input fingerprints distinguish current/earlier/unknown snapshots. Corrupt application data leaves saved build evidence visible with unknown input match; one unreadable history record does not break other cards. Returning from a standalone project refreshes the summaries. These are read-only saved outcomes, not live process status or filesystem verification. Only the latest outcome is stored; this is not a complete build history or a claim of a prior successful build after a later failure. Opening the generated preview still checks artifacts through the existing guarded workflow.

For already-migrated databases, unreadable application/generation records are retained verbatim and raise an explicit per-key error, so other projects remain accessible after restart. Invalid migration/global data and physically corrupt database files still fail startup. This does not provide automatic record repair or recovery of damaged bytes; see STORAGE.md.

## Plan and task provenance

The version-1 `asg-build` contract accepts only `flutter-starter` and its canonical resolve → analyze → test → build graph. Version 2 maps bounded unique task IDs to exactly one of each of the same four operations, listed in topological order. Dependencies must name earlier tasks; analyze/test require resolve transitively and build requires both analyze and test transitively. Analyze and test may run in either approved order; execution remains sequential and every check is mandatory. IDs use `[A-Za-z][A-Za-z0-9_-]{0,63}`. Saved graph order drives execution, history validation and task status; retry compares the complete graph with the exact approved contract before stopping preview or invoking the host. Version 3 adds a required `boardTaskId` on every task, referencing four distinct existing tasks in the current structured requirements board. Each board prerequisite must also be mapped and occur transitively before its dependent; a manually Done prerequisite cannot substitute for a mapped operation. Missing/duplicate/mixed references and references on versions 1/2 are rejected. Build and retry reread the board before host effects and at execution authorization boundaries; the approval already binds its revision. Saved graphs retain these references and show them beside actual operation status after reopen. Board links are provenance, not automatic task completion or verification of requirement acceptance; the board is not changed by execution. Version 4 permits several operations to reference the same board task, so a single starter-workflow task needs no artificial split. Every operation mapped to each board prerequisite must precede every dependent operation transitively; missing prerequisites remain invalid even when manually Done. Version 3 retains distinct references. All versions keep the same four mandatory operations and reject command text or custom source edits. Duplicate JSON members (including escaped equivalent names), unknown fields/operations and ambiguous fences fail closed. Saved outcomes retain exact approval identity and task graph; task states are pending, running, passed, failed, blocked or interrupted based on actual results. Retry requires the same approval identity and matching inputs, not a replacement approval for old source. General `asg-tasks` proposals are planning data only and cannot execute commands. Full action checkpoints/resume remain F03.


Command results now retain `cancelled` separately from timeout and output exhaustion. SIGTERM/SIGINT or observed parent loss makes a helper result fail even if the child exits zero. Legacy saved results omit this field and read as false. This records cancellation evidence when a result reaches storage; process teardown or application death does not guarantee a final saved result. User Stop controls and checkpoint resume remain F03 work.
