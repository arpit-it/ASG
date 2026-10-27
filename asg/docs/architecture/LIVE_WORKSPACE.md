# App-led creation and live workspace

ASG is a Flutter application targeting Android, iOS, web, macOS, Windows and Linux. Included platform runners do not establish tested device support. Managed MLX setup and the current independent Flutter web generator host are macOS-specific; other platforms retain supported app features and runtime connection controls.

Qwen uses the previously verified local 4-bit MLX streaming backend. Live availability must be checked each run; historical connection failures do not establish the current endpoint state. See [streaming setup](../setup/QWEN_STREAMING.md).

The normal application window is now the current project's workspace. The desktop layout has chat on the left and a running interactive prototype on the right. On narrow screens, Chat and Preview tabs preserve both panes. Projects remains available in the header, alongside new-project and runtime controls.

## App-led project setup

With no project, Studio asks what the user wants to create. The guided flow is:

1. Describe an idea or choose a starting suggestion.
2. Choose a suggested experience (mobile, browser, desktop or all devices) and first-version features.
3. Review the name, platforms, requirements and optional folder, then create the project.

Starting recommendations are deterministic and work offline; they are not presented as LLM output. The app selects Flutter architecture/platform metadata from the choices. Existing project JSON remains compatible, and selected requirements are stored in the description. Creation opens the project workspace. The selected project ID is stored at `studio.lastProject.v1` and restored on entry; if absent, the most recent saved project is used.

## Instructions apply to the visible application

Enter an instruction in chat and press **Apply instruction**. Fully recognized common commands run immediately without inference:

- `add a counter`
- `add notes called My notes`
- `add a task list`
- `change the theme to green`
- `rename the app to My Planner`
- `add a counter and change the theme to green`

Supported clauses can be combined with `and` (up to four). An unknown clause prevents the built-in path from partially applying a request. Other instructions go to the configured local model. Qwen returns bounded structured edits; unknown operations, invalid targets, unsupported controls and malformed responses are rejected.

The renderer executes actual Flutter controls from a validated application definition. Current elements are heading, text, task list, counter, editable notes and buttons. Buttons can show a message, increment a counter, clear a list or add an item. Themes are indigo, green, orange and pink. This is a live interpreted prototype with functional controls, not an image or an external compiled project. Unrestricted source synthesis and deployment remain future work. The separate macOS-hosted Flutter web generator can export, verify and serve a compiled snapshot, with reviewed scoped Dart edits and bounded consented repairs; see [generation](GENERATION.md). Selected project platform targets remain metadata; a working prototype does not establish builds on those targets.

Current list/counter/note values are supplied with the next model instruction, and stable element IDs preserve local interaction state across compatible visual updates. Application definitions and successful edit conversations are saved together as `studio.application.v1.<projectId>`. The old Discuss history remains separately stored and is not deleted or silently reinterpreted as successful edits. Prototype interactions persist through serialized/coalesced writes with visible failure and retry state; navigation waits for pending saves. The generated independent app has session-only interaction state. See [storage](STORAGE.md).

A successful update is validated and saved before the controller publishes it. The preview then rebuilds immediately and shows the new version number; chat scrolls to its response. A malformed result, timeout or failed write leaves the last working definition/revision unchanged and keeps the user's input for retry.

## Planning and requirements

The workspace exposes a persisted structured requirements/task board, editable project details, and separate Discuss/Plan/advisory Review conversations. Plans may propose additive queued tasks for explicit import; import invalidates prior approval. Exact current Plan approval and a supported structured contract gate Build. Prototype interactions/edits also invalidate approval through revision/definition context. Advisory Review reads bounded prototype and historical verification data; it does not execute checks or mark requirements verified.

Desktop panes support pointer/keyboard resizing within usable minimums and collapse/restore. Narrow screens use tabs; mounted panes preserve working state across layout changes. F14 delivery and validation are recorded in the sole [requirements queue](../REQUIREMENTS.md).

## Runtime constraints and verification

The client uses a 15-second connection/header deadline, 30-second inactive stream deadline and absolute 180-second total deadline across SSE, compatible JSON and rejection bodies. The bridge supports 4096 input tokens and at most 2048 output tokens, one request at a time, with bounded cancellation points. Larger requests fail visibly; closing transport does not prove immediate interruption of a native inference kernel.

Historical BF16 Torch attempts timed out safely. Later 4-bit MLX custom-edit, Plan and Review smoke runs succeeded, including streamed phases and durable prototype refresh. This documentation update performs no fresh inference; prior endpoint failures are historical observations. Default-skipped tests do not establish current model availability.

```sh
flutter test test/application_loop_test.dart --dart-define=ASG_REAL_INFERENCE=true --plain-name 'real local Qwen instruction'
```

See [streaming setup](../setup/QWEN_STREAMING.md), [test strategy](../development/TEST_STRATEGY.md) and [verified progress](../history/PROGRESS.md).
