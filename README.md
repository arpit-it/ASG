# Automated Software Generator

**Automated Software Generator (ASG)** is a local-first Flutter application for creating software through conversation. The intended experience is simple: describe what you want to build, choose from options proposed by the app, review the plan, and refine the result through chat while watching its preview.

The long-term goal is to generate, build, test, run and maintain many types of software without requiring a code editor in the normal workflow. The current release implements guided project planning and a bounded interactive prototype; independent source generation and autonomous build/repair are upcoming work.

## What works today

- Guided creation starts with an idea, proposes experiences/features, and saves the reviewed choices and project metadata.
- Reopening the app restores the current project. Desktop shows chat on the left and an interactive prototype on the right; narrow screens use tabs.
- Supported instructions update titles, themes and prototype elements such as tasks, counters, notes and buttons. Simple commands run locally; custom edits use the configured model. Edits validate and save before refreshing the preview, preserving the previous version on failure.
- Chat streams response text and displays thinking, writing, checking and applying progress. Cancellation is available before an accepted revision is saved.
- The upper-right runtime control supports downloaded model folders or explicit public repository downloads on macOS, runtime readiness checks and connection settings.
- Qwen3.5-9B has been verified locally with a 4-bit MLX conversion on Apple Silicon. Model weights and Python environments are kept outside Git.

## Planned capabilities

The [requirements](asg/docs/MASTER_REQUIREMENTS.md) describe approved requirements/plans, safe source generation, deterministic build/test execution, bounded repairs, actual generated-app previews, project history/resume, export and controlled self-development. Framework adapters should grow incrementally toward broad software support. These are product goals, not completed capabilities.

Current previews render a constrained application definition inside ASG; they do not compile an independent project. Transactional storage, durable prototype interaction state and a complete source generator remain open work. Linking a project folder records its location; it does not import or modify its source. See the [roadmap](asg/docs/ROADMAP.md), [progress](asg/docs/PROGRESS.md) and [open issues](https://github.com/arpit-it/ASG/issues).

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

In Android Studio, open **asg/** (the folder containing pubspec.yaml), enable Flutter/Dart plugins, select the shared **Automated Software Generator** run configuration and choose a device. See [run/debug setup](asg/docs/ANDROID_STUDIO.md).

## Configure local inference

Open the runtime control in the landing screen's upper-right corner. On macOS, choose complete downloaded model files or explicitly download a supported public repository, select a compatible Python environment, and prepare/start the runtime. If a runtime is already running, connect to it using its endpoint and model ID. A model download never starts merely by opening setup.

The verified setup uses Qwen3.5-9B, a project-local MLX environment and a locally converted checkpoint. Follow [current Qwen setup](asg/docs/QWEN_STREAMING.md) for installation, conversion and restart commands; model files are not included in this repository. Read [runtime setup](asg/docs/RUNTIME_SETUP.md) for supported checkpoint formats, download restrictions and process ownership.

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

Projects, settings and revisions currently use versioned device preferences, not a transactional database or secrets store. Preserve stored schemas and last-working application state when extending the app.

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

CI runs formatting, analysis, default tests, a web build and Python fixtures on PRs and main pushes. The real Qwen test is opt-in and skipped by default; fixture success does not prove live inference. See [CI coverage](asg/docs/CI.md), [live-test instructions](asg/docs/QWEN_STREAMING.md) and [test strategy](asg/docs/TEST_STRATEGY.md). Run relevant native builds when changing platform code.

Read [AGENTS.md](AGENTS.md), [coding standards](asg/docs/CODING_STANDARDS.md) and [Git workflow](asg/docs/GIT_WORKFLOW.md). Start with a necessary issue, use a focused codex/<issue>-<slug> branch, test/fix/retest and open a linked PR. An independent reviewer checks the final revision and passing checks before merging. Keep credentials, model weights, virtual environments and build output out of commits.

For implementation context, see [architecture](asg/docs/ARCHITECTURE.md), [live workspace](asg/docs/LIVE_WORKSPACE.md), [security](asg/docs/SECURITY.md) and [project memory](asg/docs/AGENT_MEMORY.md).
