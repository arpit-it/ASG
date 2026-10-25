# Automated Software Generator

A local-first Flutter foundation for the supplied AI Project Studio brief.

## Run

```sh
flutter pub get
flutter run -d macos
# Or select an available device with flutter devices.
flutter run -d chrome
```

Platform runners are included for Android, iOS, web, macOS, Windows, and Linux. Each native platform requires its own supported host/toolchain. Dart package name: `asg`; display name: **Automated Software Generator**.

## Current functionality

Create and search persistent project planning records, select a local folder on supported platforms, inspect project metadata, and navigate a responsive workspace. Records use a versioned JSON schema in device preferences (browser storage on web). Folder selection links metadata only; no source files are generated or modified. Settings save the local model endpoint and model ID and provide a real connection test.

## Boundaries

Plan approval, source generation, build execution, live preview, Git, and self-development are not implemented. Mode selection is UI state; no execution engine is connected. Local Qwen discussion is available through the separate Discuss button. Local folder selection is unavailable on web and iOS. Mobile layout uses a single workspace pane. SQLite, portable project export, resizable panels, and durable execution history remain future work. Preferences are suitable for this foundation, not a transactional project database or secrets store.

## Validate

```sh
flutter analyze
flutter test
flutter build macos --debug
flutter build web
```

See `docs/PROGRESS.md` for verified results and remaining scope.

## Android Studio

Open this project's root folder (containing `pubspec.yaml`), enable the Flutter/Dart plugins, and select the shared **Automated Software Generator** run configuration. Choose an Android device and click Run or Debug. See [Android Studio setup](docs/ANDROID_STUDIO.md) for SDK prerequisites and troubleshooting.

## Qwen 9B

The initial local model is the existing Qwen3.5-9B checkpoint. Configure its endpoint in dashboard Settings, use **Test model**, or open a project and choose **Discuss with Qwen 9B**. See [local Qwen runtime](docs/LOCAL_QWEN.md) for the Mac launch command and Android Emulator settings. Model responses are real; source generation and execution remain unavailable.

## Project structure (MVC)

- `lib/models/` — domain data
- `lib/views/` — screens and presentation
- `lib/controllers/` — state, validation, and workflows
- `lib/services/` — persistence, local AI transport, and platform integrations

See [architecture](docs/ARCHITECTURE.md) and the repository's `AGENTS.md` for conventions when adding features.

Project development instructions: [Coding standards](docs/CODING_STANDARDS.md). Follow these when adding or changing features.

## Runtime setup

Use the landing screen's upper-right runtime FAB to choose downloaded model files or explicitly download a model repository, prepare a Python runtime and connect chat. Managed setup currently targets Qwen3.5 Safetensors on macOS. See [Runtime setup](docs/RUNTIME_SETUP.md) for requirements, platform behavior and the approved macOS host-access boundary.

## Default workspace and chat edits

The current project now reopens with chat on the left and its live interactive prototype on the right. New users are guided from an idea through experience/features and review. Try **add a counter and change the theme to green** in chat, then **Apply instruction**. Supported local commands refresh immediately; other edits use the configured model and are validated before replacing the working version.

This is a bounded in-app prototype runtime, not arbitrary source generation or an external build preview. See [live workspace behavior and limits](docs/LIVE_WORKSPACE.md).


## Optimized Qwen streaming runtime

The local Qwen9B timeout has been resolved for the verified custom-edit test with a project-local 4-bit MLX conversion. Chat now streams actual response text and shows thinking/writing/applying status, with cancellation and validation-before-refresh. See [current Qwen setup](docs/QWEN_STREAMING.md). The hourly development schedule reads [durable project memory](docs/AGENT_MEMORY.md). Public origin: [arpit-it/ASG](https://github.com/arpit-it/ASG).

Contribution workflow: [Git workflow](docs/GIT_WORKFLOW.md). New implementations start from a GitHub issue and use a dedicated branch and PR.
