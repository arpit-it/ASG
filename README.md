# Automated Software Generator

**Automated Software Generator (ASG)** is a local-first Flutter application for creating software through conversation. The intended experience is simple: describe what you want to build, choose from options proposed by the app, review the plan, and refine the result through chat while watching its preview.

The long-term goal is to generate, build, test, run and maintain many types of software without requiring a code editor in the normal workflow. The current release implements guided planning, a durable interactive prototype, and an approved Flutter web MVC source-generation/verification slice. Reviewed scoped Dart edits, bounded consented automatic repairs, history/rollback and portable backup/restore are also delivered within the supported Flutter workflow; unrestricted multi-framework synthesis remains future work.

## What works today

- Guided creation starts with an idea, proposes experiences/features, and saves the reviewed choices and project metadata.
- Reopening the app restores the current project. Desktop shows resizable/collapsible chat and prototype panes; narrow screens use tabs.
- Supported instructions update titles, themes and prototype elements such as tasks, counters, notes and buttons. Simple commands run locally; custom edits use the configured model. Edits validate and save before refreshing the preview, preserving the previous version on failure.
- Chat streams response text and displays thinking, writing, checking and applying progress. Cancellation is available before an accepted revision is saved.
- The upper-right runtime control supports downloaded model folders or explicit public repository downloads on macOS, runtime readiness checks and connection settings.
- **Edit project details** revises a saved project's name and requirements. The running app and chat stay intact; future exports use the revised requirements and earlier exports show as outdated. Change the app itself through chat.
- Project cards show saved generation/verification outcomes and whether their inputs match the current app and requirements. Unreadable history is explicit; a saved pass does not assert that a preview is running or artifacts are unchanged.
- On macOS, **Generate Flutter source** exports a fixed MVC starter into a new folder, runs bounded offline analysis/tests/web build, and serves the actual compiled app through an explicit browser preview. See [source generation](asg/docs/architecture/GENERATION.md) for setup, approval, reviewed scoped source edits, bounded consented repair, recovery and limits.
- Qwen3.5-9B has been verified locally with a 4-bit MLX conversion on Apple Silicon. Model weights and Python environments are kept outside Git.

## Planned capabilities

The [requirements](asg/docs/REQUIREMENTS.md) are the single feature queue. F10 deterministic acceptance verification remains In progress; additional project adapters, hardware-aware inference, portable generator hosting, broader product verification and isolated self-development remain planned.

The default preview renders a constrained definition inside ASG. The macOS-hosted generation flow separately compiles an independent Flutter web snapshot and supports reviewed replacements of recorded Dart files plus bounded consented automatic repairs. Build history/explicit rollback, read-only existing Flutter project inspection with imported-plan approval, and portable project backup/restore are delivered; import approval does not authorize modifying arbitrary imported source. See [generation limits](asg/docs/architecture/GENERATION.md) and the requirements ledger for precise boundaries and evidence. Linking a folder by itself only records its location.

## Run the app

Use Flutter **3.47.6** with Dart **3.13.5** (the CI-pinned version), Git and the toolchain required by your target platform.

```sh
git clone https://github.com/arpit-it/ASG.git
cd ASG/asg
flutter doctor -v
flutter pub get --enforce-lockfile
flutter devices
flutter run -d macos
# Or select another available device, for example:
flutter run -d chrome
```

Platform runners are included for Android, iOS, web, macOS, Windows and Linux. Each native build requires a supported host and platform SDK; runners do not establish that every device has been tested. Android debug, macOS debug and web builds have passed locally. Physical-device launches and the remaining native targets are not verified.

In Android Studio, open **asg/** (the folder containing pubspec.yaml), enable Flutter/Dart plugins, select the shared **Automated Software Generator** run configuration and choose a device. See [run/debug setup](asg/docs/setup/ANDROID_STUDIO.md).

## Configure local inference

Open the runtime control in the landing screen's upper-right corner. On macOS, choose complete downloaded model files or explicitly download a supported public repository, select a compatible Python environment, and prepare/start the runtime. If a runtime is already running, connect to it using its endpoint and model ID. A model download never starts merely by opening setup.

The verified setup uses Qwen3.5-9B, a project-local MLX environment and a locally converted checkpoint. Follow [current Qwen setup](asg/docs/setup/QWEN_STREAMING.md) for installation, conversion and restart commands; model files are not included in this repository. Read [runtime setup](asg/docs/setup/RUNTIME_SETUP.md) for supported checkpoint formats, download restrictions and process ownership.

Managed local model setup currently targets macOS. Other platforms expose connection controls. The bridge binds to the host's loopback interface; macOS/local browser use `http://127.0.0.1:8765/v1`, while the Android Emulator uses `http://10.0.2.2:8765/v1`. Physical-phone connectivity is not configured. Running ASG on a phone does not run the Mac's model there. Initial dependency/model setup needs downloads; local inference can run offline afterward.

The macOS build has App Sandbox disabled with the owner's approval so it can launch the selected host Python runtime and access model files. It runs with host-user permissions; this is not an execution sandbox for generated code.

## Project structure

The Flutter root is **asg/** and follows MVC with integration services:

| Path | Responsibility |
| --- | --- |
| asg/lib/models/ | Typed domain data, validation and serialization |
| asg/lib/views/ | Screens, rendering and presentation |
| asg/lib/controllers/ | State and application workflows |
| asg/lib/services/ | Persistence, model transport and platform integrations |
| asg/test/ | Unit, controller, widget and integration checks |
| asg/tools/ | Runtime bridge, model downloader and lightweight fixtures |
| asg/docs/ | Requirements, architecture, setup, progress and durable memory |
| .github/ | CI, issue forms and PR template |

Projects, conversations, settings and application revisions use a transactional Sembast database (native app-support file; IndexedDB on web). Existing preference records migrate atomically and remain retained as the original backup. Prototype tasks/completion, counters and notes save across restarts, with visible failure/retry state. Storage is not a secrets store. See [storage and recovery](asg/docs/architecture/STORAGE.md); preserve stored schemas and last-working state when extending the app.

## Validate and contribute

Run from **asg/**:

```sh
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
python3 -B tools/test_download_model.py
python3 -B tools/test_qwen_streaming_server.py
flutter build web
```

CI runs formatting, analysis, default tests, a web build and Python fixtures on PRs and main pushes. The real Qwen test is opt-in and skipped by default; fixture success does not prove live inference. See [CI coverage](asg/docs/development/CI.md), [live-test instructions](asg/docs/setup/QWEN_STREAMING.md) and [test strategy](asg/docs/development/TEST_STRATEGY.md). Run relevant native builds when changing platform code.

Read [AGENTS.md](AGENTS.md), [coding standards](asg/docs/development/CODING_STANDARDS.md) and [Git workflow](asg/docs/development/GIT_WORKFLOW.md). Start with a necessary issue, use a focused `<issue-number>-<short-description>` branch, test/fix/retest and open a linked PR. An independent reviewer checks the final revision and passing checks before merging. Keep credentials, model weights, virtual environments and build output out of commits.

For implementation context, see [architecture](asg/docs/architecture/ARCHITECTURE.md), [live workspace](asg/docs/architecture/LIVE_WORKSPACE.md), [security](asg/docs/development/SECURITY.md) and [project memory](asg/docs/history/AGENT_MEMORY.md).

Repository contributions follow [CONTRIBUTING.md](CONTRIBUTING.md) and the [security policy](SECURITY.md). Main is protected by required PRs and passing CI; external workflow runs require maintainer approval.

Saved generated builds are labeled against the current app/project inputs. After chat or interaction changes, earlier builds remain explicitly previewable; generating a new folder captures the updated state.

## Platform and planning scope

ASG is a Flutter application targeting Android, iOS, web, macOS, Windows and Linux. Included platform runners do not establish tested device support. Managed MLX setup and the current independent Flutter web generator host are macOS-specific; other platforms retain supported app features and runtime connection controls.

The structured requirements/task board is implemented (F01). Discuss, Plan and advisory Review persist separately from prototype-edit chat. A saved Plan can propose additive queued tasks for explicit import; import changes the requirements revision and requires a fresh Plan before approval. The fixed starter contract has readable task/dependency preview, explicit durable approval/withdrawal, and saved per-task outcomes. Build requires the exact latest Plan, requirements and prototype context plus separate operation consent. Legacy drafts require a fresh Plan. F02 approved structured execution and F03 safe bounded resume are delivered for the supported adapter. F04 supports reviewed scoped Dart edits; F05 supports bounded consented automatic repairs. F06 history/rollback, F07 read-only Flutter import/imported-plan approval and F08 portable backup/restore are delivered within their documented limits. These do not grant arbitrary command execution or general multi-framework synthesis. See the [requirements and task queue](asg/docs/REQUIREMENTS.md).
