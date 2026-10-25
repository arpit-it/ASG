# Flutter project instructions and coding standards

Applies to Automated Software Generator. Updated: 25 October 2026.

## Working directory and scope

- Repository: `/Users/arpitsinha/AndroidStudioProjects/ASG`.
- Flutter application: `asg/`. Run Flutter commands from that directory.
- Preserve the existing Git history, package `asg`, application identifiers, and unrelated local changes.
- Inspect the affected code and repository instructions before editing. Implement small, working increments and report the checks actually performed.
- Follow direct user requirements. Record significant architecture changes in `TECHNICAL_DECISIONS.md`; routine implementation decisions do not need a separate approval step.

## Architecture: MVC with services

Use these responsibilities for every new feature:

| Folder | Responsibility | Keep out |
| --- | --- | --- |
| `lib/models/` | Typed domain records, pure validation, serialization helpers | Widgets, storage plugins, network requests |
| `lib/views/` | Layout, rendering, navigation, form/text controller lifecycle | Persistence logic, model requests, business workflows |
| `lib/controllers/` | Observable feature state, validation, workflow coordination, service calls | Widgets, `BuildContext`, dialogs, navigation |
| `lib/services/` | Storage/repositories, HTTP transport, platform APIs and execution policy | Screen layout and navigation |
| `lib/main.dart` | Bootstrap and top-level startup handling | Feature logic |

Flow: view event → controller action → service → updated controller state → view redraw.

Split screens and controllers by feature. Keep classes focused. Extract a shared component when reuse or a distinct responsibility justifies it; avoid speculative abstraction. Use constructor injection or provider factories at integration boundaries. Do not introduce a dependency-injection or state-management package just to wrap existing code.

The project uses `ChangeNotifier` controllers and view-owned subscriptions. Keep UI state and application state separate: focus, animation and text input belong to the view; persisted records, async operations and business validation belong to the controller/service layers. Expose read-only collections and keep mutable state private when introducing or revising controller APIs.

Flutter's official architecture guidance favors MVVM. This project deliberately uses the user's requested MVC naming while retaining separation of UI/data, observable state, and dependency injection. Do not claim MVC is Flutter's mandated architecture or switch architectural patterns without a concrete need.

## Dart style and maintainability

- Follow Effective Dart and the repository's `flutter_lints` configuration. Format with `dart format`.
- Use `lowercase_with_underscores.dart`, `UpperCamelCase` for types, and `lowerCamelCase` for members. Name new feature controllers `FeatureController`, views `FeatureView` or `FeatureScreen`, and integration classes by responsibility.
- Prefer `final`, immutable typed models, enums for finite states, and `const` widgets where applicable.
- Avoid `dynamic`, raw maps and forced null assertions in domain/application code. Confine JSON shape handling and unavoidable casts to serialization or transport boundaries; validate untrusted input there.
- Keep functions readable and focused. Comment intent, assumptions and non-obvious limits; do not narrate obvious statements.
- Use explicit return types on public methods and meaningful names. Document public abstractions whose lifecycle or behavior is non-obvious.
- Do not silence analyzer warnings broadly. A local suppression needs a specific reason.

## Async work and lifecycle

- Show explicit loading, success/empty and failure states for asynchronous workflows. Prevent duplicate submissions while an operation is active.
- Await operations whose result or failure matters. For deliberate fire-and-forget cleanup, make ownership and error handling explicit.
- Dispose owned listeners, text controllers, streams and clients. Never update a disposed controller or call UI APIs after an async gap without checking `mounted`.
- Keep persistence ordering deliberate: do not publish successful state before the corresponding write succeeds. Preserve user input or saved history when an operation fails.
- Provide timeouts and cancellation at external boundaries. State what cancellation actually does; closing an HTTP client does not prove server-side inference stopped.
- Keep CPU-heavy parsing, inference and builds off the Flutter UI thread. Profile before adding isolates or caching.

## Persistence and integration

- Access preferences, files and network clients through services/repositories. Controllers coordinate them; views display outcomes.
- Preserve current keys and record formats: `studio.projects.v1`, `studio.localModel.v1`, `studio.chat.v1.<projectId>`. Add a tested migration before changing durable schemas.
- Treat corrupted saved data as an error; do not silently replace it with an empty database.
- Production records use transactional storage behind RecordStorage. Preserve atomic migration and retained legacy preference backups; see STORAGE.md. Do not use preferences for new production writes or either store for secrets.
- Keep runtime/model configuration outside orchestration logic. Current initial model: existing local Qwen3.5-9B; see `LOCAL_QWEN.md` for its location, setup and limits.
- Keep HTTP endpoints configurable, validate allowed destinations, close clients, and return actionable errors without logging prompts, credentials or sensitive filesystem content.
- Do not hardcode machine-specific model/SDK paths in reusable Dart features. Machine setup belongs in configuration and setup documentation.

## UI and cross-platform behavior

- Use shared theme/color/text styles and Material components consistently. Extract repeated visual elements into focused reusable views.
- Design for available constraints rather than a particular device. Check narrow screens, desktop widths, text scaling, keyboard focus, scrolling and error content.
- Give icon-only controls meaningful tooltips/semantics. Keep labels clear and touch targets usable. Avoid communicating status through color alone.
- Handle unsupported platform APIs explicitly and preserve a usable fallback. Keep platform-specific implementation behind services.
- Preserve loading/error behavior when redesigning screens. Display actual model/build/test state and distinguish unavailable features from working ones.
- Browser and mobile builds do not imply that a phone can run or access a Mac-local 9B model. Document host connectivity and platform restrictions.

## Execution and dependency safety

- Add dependencies only for a concrete requirement; review compatibility and license terms, and keep `pubspec.lock` for this application.
- Never commit secrets, model weights, local runtime dependencies, SDK paths, build output or private IDE state.
- Future generated-code tools must enforce project path scope, validate structured actions, bound retries/time/output and honor plan approval. A policy class alone does not enforce an execution sandbox.
- Never overwrite existing user project files or alter the installed stable app during self-development. Initial generation uses the fixed Flutter web starter. Reviewed scoped Dart candidates require explicit confined verification/promotion; unrestricted source execution and self-development remain unavailable. See GENERATION.md.
- Future generated Flutter templates should follow this MVC structure when their generator is implemented. Do not represent this standards document as a working generator.

## Tests and completion checks

For code changes, run from `asg/`:

```sh
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
```

Run the relevant platform build when runtime code, imports, dependencies, or platform configuration change. Android debug build: `flutter build apk --debug`; web build: `flutter build web`; macOS build: `flutter build macos --debug`.

Test controller behavior independently with fake providers/services. Prioritize persistence ordering, validation, network errors, cancellation/disposal, and restored state. Use widget tests for user interactions and responsive behavior. Avoid tests that merely repeat the implementation. Keep `test/architecture_test.dart` passing; extend its boundary checks when adding new integration paths.

A successful build does not establish a successful device launch. Report verified platforms and any remaining limits precisely. Update `PROGRESS.md` for completed increments, including tests, build outcomes and known issues. Documentation-only changes do not require rerunning unrelated builds.

## Current enforcement and remaining work

Current enforcement: Flutter lints, formatter, architecture boundary tests, controller/unit/widget tests, native database reopen and actual Chrome storage coverage, Python runtime/process fixtures, web build and real independent generated-project verification in CI. Issue #50 locally passes 200 default tests (four opt-in skips), analysis and web build; older counts describe historical increments. The standards above govern future changes; they do not assert that accessibility, all device layouts, strict JSON validation, fully private controller state, transactional storage, or every platform has already been audited.

## References

- [Effective Dart](https://dart.dev/effective-dart)
- [Flutter architecture recommendations](https://docs.flutter.dev/app-architecture/recommendations)
- Project details: `ARCHITECTURE.md`, `LOCAL_QWEN.md`, `SECURITY.md`, `TEST_STRATEGY.md`.


## Git delivery

Follow root AGENTS.md and GIT_WORKFLOW.md: issue first, a separate <issue>-<slug> branch per new implementation, focused commits, verified checks, feature-branch push and a linked PR to main. The initial baseline has a one-time owner-authorized direct-main publication exception; subsequent work does not.

## Product/platform terminology

ASG is a Flutter application targeting Android, iOS, web, macOS, Windows and Linux. Included platform runners do not establish tested device support. Managed MLX setup and the current independent Flutter web generator host are macOS-specific; other platforms retain supported app features and runtime connection controls. Refer to the app as Flutter/cross-platform; reserve “macOS-only” for a specifically limited host integration. Preserve historical SwiftUI/macOS proposals as superseded provenance rather than current implementation guidance.
