# Automated Software Generator — Flutter application

This directory contains the cross-platform Flutter app. The [repository README](../README.md) is the primary overview of the product requirements, implemented capabilities, planned work, runtime limitations and contribution workflow.

ASG guides users from an idea through proposed options to an interactive prototype. The current project reopens with chat and live preview; validated chat instructions save a new revision before refreshing it. Qwen3.5-9B chat streams text with visible progress. An approved macOS-hosted Flutter web MVC generation flow can create, verify and serve an independent snapshot; reviewed scoped Dart replacements and bounded consented automatic repair are delivered, while unrestricted source synthesis remains planned. See [generation setup and limits](docs/architecture/GENERATION.md).

## Run from this directory

Use Flutter 3.47.6 / Dart 3.13.5 and the platform's supported toolchain:

```sh
flutter pub get --enforce-lockfile
flutter devices
flutter run -d macos
# Or choose another available device:
flutter run -d chrome
```

Android Studio should open this folder and use the shared **Automated Software Generator** run/debug configuration. See [Android Studio setup](docs/setup/ANDROID_STUDIO.md).

Platform runners cover Android, iOS, web, macOS, Windows and Linux. Managed model scanning/download/startup currently targets macOS; other platforms connect to an accessible runtime. Model weights and Python environments are not bundled. Use the upper-right runtime control and follow [current Qwen streaming setup](docs/setup/QWEN_STREAMING.md) and [runtime setup](docs/setup/RUNTIME_SETUP.md).

## Development references

- [Requirements](docs/REQUIREMENTS.md), [roadmap](docs/history/ROADMAP.md) and [verified progress](docs/history/PROGRESS.md)
- [MVC architecture](docs/architecture/ARCHITECTURE.md), [coding standards](docs/development/CODING_STANDARDS.md) and [repository instructions](../AGENTS.md)
- [Validation and CI](docs/development/CI.md), [test strategy](docs/development/TEST_STRATEGY.md) and [live prototype limits](docs/architecture/LIVE_WORKSPACE.md)
- [Git workflow](docs/development/GIT_WORKFLOW.md), [security](docs/development/SECURITY.md) and [durable project memory](docs/history/AGENT_MEMORY.md)

Run formatting, analysis, tests and a relevant build before publishing implementation changes. New work uses an issue, a separate branch and an independently reviewed PR.

Use **Edit project details** in the workspace toolbar to revise the current project's name and requirements. Saving preserves the current app and conversation across restart; chat changes the prototype. Future source exports include the revised requirements, and existing exports are labeled outdated. The editor waits for active work and preview saves to finish.

## Platform and planning scope

ASG is a Flutter application targeting Android, iOS, web, macOS, Windows and Linux. Included platform runners do not establish tested device support. Managed MLX setup and the current independent Flutter web generator host are macOS-specific; other platforms retain supported app features and runtime connection controls.

The structured requirements/task board is implemented (F01). Discuss, Plan and advisory Review persist separately from prototype-edit chat. A saved Plan can propose additive queued tasks for explicit import; import changes the requirements revision and requires a fresh Plan before approval. The fixed starter contract has readable task/dependency preview, explicit durable approval/withdrawal, and saved per-task outcomes. Build requires the exact latest Plan, requirements and prototype context plus separate operation consent. Legacy drafts require a fresh Plan. F02 approved structured execution and F03 safe bounded resume are delivered for the supported adapter. F04 supports reviewed scoped Dart edits; F05 supports bounded consented automatic repairs. F06 history/rollback, F07 read-only Flutter import/imported-plan approval and F08 portable backup/restore are delivered within their documented limits. These do not grant arbitrary command execution or general multi-framework synthesis. See the [requirements and task queue](docs/REQUIREMENTS.md).
