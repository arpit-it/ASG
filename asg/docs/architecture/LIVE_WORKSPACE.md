# App-led creation and live workspace

**Current runtime update:** Qwen now uses the verified local 4-bit MLX streaming backend. The earlier Torch timeout/nonstreaming notes below are historical. See [QWEN_STREAMING.md](../setup/QWEN_STREAMING.md) for current setup, limits and successful real-edit verification.

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

The renderer executes actual Flutter controls from a validated application definition. Current elements are heading, text, task list, counter, editable notes and buttons. Buttons can show a message, increment a counter, clear a list or add an item. Themes are indigo, green, orange and pink. This is a live interpreted prototype with functional controls, not an image or an external compiled project. Generating/exporting arbitrary application source, independent process previews, builds and deployment remain future work. Selected project platform targets remain metadata; a working prototype does not establish builds on those targets.

Current list/counter/note values are supplied with the next model instruction, and stable element IDs preserve local interaction state across compatible visual updates. Application definitions and successful edit conversations are saved together as `studio.application.v1.<projectId>`. The old Discuss history remains separately stored and is not deleted or silently reinterpreted as successful edits. Runtime interactions not yet included in a saved instruction revision are session state; a full data-storage engine for generated apps is future work.

A successful update is validated and saved before the controller publishes it. The preview then rebuilds immediately and shows the new version number; chat scrolls to its response. A malformed result, timeout or failed write leaves the last working definition/revision unchanged and keeps the user's input for retry.

## Runtime constraints and verification

Qwen uses the existing local provider, with compact edit requests and up to 2048 response tokens for application updates. The bridge now accepts that output budget; normal Discuss defaults stay at 256. The bridge has a 4096 input-token limit. Larger applications/instructions can exceed these limits and will fail visibly. Model generation max-time is checked between generation steps, so slow prefill can exceed it. Client timeout remains 120 seconds; disconnecting does not prove the server generation stopped.

The initial full-definition real-model edit test timed out under current Mac memory pressure. The process started for that test was reset to restore runtime availability. Do not describe arbitrary Qwen edits as verified solely from deterministic or mocked tests. Common built-in instructions have an actual widget-level submit/save/refresh test, and the model path has fake-provider validation/error tests. The opt-in live test can be run alone with:

```sh
flutter test test/application_loop_test.dart --dart-define=ASG_REAL_INFERENCE=true --plain-name 'real local Qwen instruction'
```

See PROGRESS.md for final results of the current increment.

Final runtime check for this increment: compact structured edits also timed out at the 120-second client limit. Two real edit attempts failed safely; 40 regular tests passed. Custom Qwen editing should be treated as performance-limited on this environment, while supported deterministic instruction updates are verified and available. No model was downloaded or converted as part of this change.
