# Automated Software Generator — Flutter application

This directory contains the cross-platform Flutter app. The [repository README](../README.md) is the primary overview of the product requirements, implemented capabilities, planned work, runtime limitations and contribution workflow.

ASG guides users from an idea through proposed options to an interactive prototype. The current project reopens with chat and live preview; validated chat instructions save a new revision before refreshing it. Qwen3.5-9B chat streams text with visible progress. Independent source generation, autonomous builds/repairs and export remain planned.

## Run from this directory

Use Flutter 3.47.6 / Dart 3.13.5 and the platform's supported toolchain:

```sh
flutter pub get --enforce-lockfile
flutter devices
flutter run -d macos
# Or choose another available device:
flutter run -d chrome
```

Android Studio should open this folder and use the shared **Automated Software Generator** run/debug configuration. See [Android Studio setup](docs/ANDROID_STUDIO.md).

Platform runners cover Android, iOS, web, macOS, Windows and Linux. Managed model scanning/download/startup currently targets macOS; other platforms connect to an accessible runtime. Model weights and Python environments are not bundled. Use the upper-right runtime control and follow [current Qwen streaming setup](docs/QWEN_STREAMING.md) and [runtime setup](docs/RUNTIME_SETUP.md).

## Development references

- [Requirements](docs/MASTER_REQUIREMENTS.md), [roadmap](docs/ROADMAP.md) and [verified progress](docs/PROGRESS.md)
- [MVC architecture](docs/ARCHITECTURE.md), [coding standards](docs/CODING_STANDARDS.md) and [repository instructions](../AGENTS.md)
- [Validation and CI](docs/CI.md), [test strategy](docs/TEST_STRATEGY.md) and [live prototype limits](docs/LIVE_WORKSPACE.md)
- [Git workflow](docs/GIT_WORKFLOW.md), [security](docs/SECURITY.md) and [durable project memory](docs/AGENT_MEMORY.md)

Run formatting, analysis, tests and a relevant build before publishing implementation changes. New work uses an issue, a separate branch and an independently reviewed PR.
