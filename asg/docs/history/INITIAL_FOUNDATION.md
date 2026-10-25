# Initial foundation history

## Current context — 25 October 2026

ASG is a Flutter application targeting Android, iOS, web, macOS, Windows and Linux. Included platform runners do not establish tested device support. Managed MLX setup and the current independent Flutter web generator host are macOS-specific; other platforms retain supported app features and runtime connection controls.

F01/F13 are Done; F02 remains In progress. PR #49 was independently reviewed and merged as `34da5bebf1728e969d9c43a661d30e4454e13f09`. Issue #50 / PR #51 adds prototype-bound approval and this documentation audit; it is Awaiting merge until final-head review and required CI pass. The [requirements ledger](../REQUIREMENTS.md) is the sole task queue. Older entries below are chronological evidence, not current instructions or an alternate backlog. Earlier SwiftUI/macOS-only, preference-only, BF16 timeout, test-count and pending-PR statements are superseded by later entries.

Historical notes from the original planning-only Flutter foundation, retained for provenance. Current behavior is documented separately.


## Acceptance Criteria

# Acceptance Criteria

Current increment: empty dashboard is honest; blank project name is rejected; target selection is required; project record saves before appearing; saved records load at startup; search filters names; unsupported automation displays explicit status. Remaining original milestone requirements include editable settings and full folder import. Generated applications, Git initialization, and successful builds must never be claimed based only on record creation.


## Android Studio

# Run and debug in Android Studio

1. In Android Studio, use **File → Open** and select the Flutter project root, the folder containing `pubspec.yaml`:
   `/Users/arpitsinha/Documents/ChatGPT/Automated Software Generator`
   Opening only its `android/` subfolder does not load the shared Flutter configuration.
2. In **Settings → Plugins**, enable/install **Flutter** and its **Dart** dependency. Restart the IDE if requested.
3. In **Settings → Languages & Frameworks → Flutter**, set the Flutter SDK to `/Users/arpitsinha/flutter` on this machine. Other machines should use their own SDK location.
4. Run **Flutter Pub Get** from `pubspec.yaml`, or run `flutter pub get` in the project terminal.
5. Select **Automated Software Generator** in the run configuration dropdown. The shared `.run/Automated Software Generator.run.xml` targets `lib/main.dart`. If the project was already open, reopen it to discover the configuration.
6. Select an Android emulator or attached Android device in the Flutter device dropdown. Use **Tools → Device Manager** to create/start an emulator, or enable USB debugging on a physical device.
7. Click **Run** or **Debug**. Both use the same Flutter configuration; Debug enables Dart breakpoints and the Flutter debugger. The device is intentionally selected in the IDE rather than hardcoded in the shared configuration.

## Required Android SDK setup on this machine

The environment check found Android SDK 36 installed but **Android SDK Command-line Tools** missing and Android license status unresolved. A run configuration does not install these components.

In **Tools → SDK Manager → SDK Tools**, install **Android SDK Command-line Tools (latest)**. Check that Android SDK Platform-Tools, Build-Tools, and the SDK platform requested by Gradle are installed. Then run:

```sh
flutter doctor --android-licenses
flutter doctor -v
flutter devices
```

Read and accept the SDK terms yourself. Resolve any remaining Android toolchain errors reported by Flutter Doctor. Android Studio's bundled JDK is the normal Gradle JDK choice; do not commit machine-specific SDK or JDK paths.

## Verification

The shared run configuration XML and its entry point have been checked. An Android APK build/device launch has not been verified; the Android SDK prerequisites above remain outstanding.


## Architecture

# Architecture

Flutter Material UI → typed StudioProject model → StudioStore → shared_preferences. ModelProvider defines streaming generation/cancellation without selecting a checkpoint. ExecutionPolicy only permits modifications in Build with plan approval; no tool execution is wired. Desktop uses a three-pane workspace at wide widths, two panes at medium widths, and one pane on mobile.


## Dependencies

# Dependency inventory

Resolved packages from pubspec.lock; bundled notices remain authoritative. No model checkpoint is included.

| Package | License file |
| --- | --- |
| args | Present in package |
| async | Present in package |
| boolean_selector | Present in package |
| characters | Present in package |
| clock | Present in package |
| collection | Present in package |
| cross_file | Present in package |
| cupertino_icons | Present in package |
| fake_async | Present in package |
| ffi | Present in package |
| file | Present in package |
| file_selector | Present in package |
| file_selector_android | Present in package |
| file_selector_ios | Present in package |
| file_selector_linux | Present in package |
| file_selector_macos | Present in package |
| file_selector_platform_interface | Present in package |
| file_selector_web | Present in package |
| file_selector_windows | Present in package |
| flutter_lints | Present in package |
| http | Present in package |
| http_parser | Present in package |
| jni | Present in package |
| jni_util | Present in package |
| leak_tracker | Present in package |
| leak_tracker_flutter_testing | Present in package |
| leak_tracker_testing | Present in package |
| lints | Present in package |
| matcher | Present in package |
| material_color_utilities | Present in package |
| meta | Present in package |
| package_config | Present in package |
| path | Present in package |
| path_provider_linux | Present in package |
| path_provider_platform_interface | Present in package |
| path_provider_windows | Present in package |
| platform | Present in package |
| plugin_platform_interface | Present in package |
| shared_preferences | Present in package |
| shared_preferences_android | Present in package |
| shared_preferences_foundation | Present in package |
| shared_preferences_linux | Present in package |
| shared_preferences_platform_interface | Present in package |
| shared_preferences_web | Present in package |
| shared_preferences_windows | Present in package |
| source_span | Present in package |
| stack_trace | Present in package |
| stream_channel | Present in package |
| string_scanner | Present in package |
| term_glyph | Present in package |
| test_api | Present in package |
| typed_data | Present in package |
| vector_math | Present in package |
| vm_service | Present in package |
| web | Present in package |
| xdg_directories | Present in package |

Review exact license terms before commercial distribution. Flutter/Dart and platform SDK terms also apply.


## Progress

# Progress — 25 October 2026

## Environment / milestone 0

Empty starting repository. Flutter 3.47.6 / Dart 3.13.5, macOS 27.0.1, Xcode 27.0, Git 2.54.0, Python 3.12.8 available. Android SDK exists but command-line tools are missing and license status is unresolved. Windows/Linux host builds unavailable on macOS. Local model/runtime compatibility and memory benchmarks are deferred; no model has been downloaded or selected.

## Foundation / milestone 1 increment

Created Flutter runners for Android, iOS, web, macOS, Windows, Linux. Implemented dashboard, search, validated project creation, persistent versioned project records, supported native folder selection, metadata workspace, configuration status, model provider interface, and an approval policy with three-repair limit. Display name: Automated Software Generator.

Validation: static analysis passed; three automated tests passed (persistence, approval policy, project creation/validation/search). Release web build passed, including compiler Wasm dry run. macOS first build compiled but signing failed due to bundle extended attributes; the normal Flutter build retry also hit signing attributes. Copying the compiled bundle to `/private/tmp/automated-software-generator-preview/Automated Software Generator.app` with `ditto --noextattr --norsrc`, then ad-hoc signing succeeded and Launch Services accepted the launch. This workaround does not establish a clean standard macOS build. iOS, Android, Windows, and Linux builds unverified. Real picker/restart/device acceptance remains manual.

Original milestone 1 is partial: existing-repository import and editable settings are deferred. UI modes do not implement conversation or approval. No real inference, source generator, tool execution, build orchestration, preview, or self-development is implemented. No generated project build/test success is fabricated.

Next: complete settings/import, migrate storage to transactional records, verify a compatible local runtime and checkpoint/license, then implement persisted Discuss/Plan and explicit plan approval before adding execution.

## Android Studio run/debug setup

Added a version-controlled `.run/Automated Software Generator.run.xml` Flutter configuration targeting `lib/main.dart`, usable for both Run and Debug with an IDE-selected device. Added `docs/ANDROID_STUDIO.md` and README setup instructions. Configuration XML/entry point validated. Android build and launch remain unverified: command-line tools are missing and SDK licenses require user review.


## Roadmap

# Roadmap

1. Flutter foundation and planning records (current partial milestone). 2. Transactional storage, editable requirements, real settings and existing-project import. 3. Verified local model adapter and persisted Discuss/Plan chat with approval. 4. Safe Flutter generator, deterministic build/test pipeline, actual preview, bounded repairs. 5. Isolated self-development and manual merge approval. Other template types remain metadata choices only.


## Security

# Security

No shell execution, source mutation, model downloads, or generated-code execution is exposed by the application. Picked paths are metadata, not trusted filesystem boundaries. Future tooling must canonicalize paths, prevent symlink escapes, enforce limits, redact secrets, audit actions, and request required approvals. macOS picker entitlement is enabled. Browser/device preferences are not encrypted secret storage. No sandbox claim applies to future child processes.


## Technical Decisions

# Technical Decisions

Flutter replaces SwiftUI at the user’s explicit request. Use platform plugins for folder selection and small local records. Versioned JSON preferences keep the initial increment small; migrate to SQLite before execution history or large conversations. No model checkpoint or inference runtime is bundled or verified. Runtime licensing and memory benchmarks are gates for milestone 2.


## Test Strategy

# Test Strategy

Unit tests verify record serialization/persistence and mode/approval policy. Widget test verifies required name validation, project creation, and search. Analyze all Dart source. Compile macOS and web on this host. Other native builds require their platform toolchains and have not been established by these tests. Real device persistence, folder-picker interaction, and restart acceptance require manual verification.
