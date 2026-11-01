# Standalone engineering Ask

Ask is available on the landing screen and in the home/workspace toolbar without creating a project. It uses the saved local model settings. Ask answers engineering questions and pasted code, streams advisory text and selectable fenced code, and retains follow-up context from the selected standalone conversation. Model suggestions may be wrong; no files, repositories or commands are exposed to the model. No answer is an executed or tested result. Copying suggestions into Code Lab or a project is a separate explicit workflow; Code Lab remains queued.

Use **New Ask conversation** or **Saved Ask conversations** to change context. Reopening Ask selects the most recently updated conversation; older conversations remain selectable. Project chat/approval data never enters Ask's prompt. Ctrl/Command + Enter submits a question. The entire screen scrolls with keyboard insets and larger text; code blocks scroll horizontally. The home/workspace toolbar keeps Ask first in a bounded horizontally scrollable action region, with an owned scrollbar, so all controls remain reachable on narrow windows. The project composer also scrolls when enlarged text or limited height requires it.

Questions are bounded to 8,000 UTF-16 characters, complete request context to 24,000, individual answers to 24,000, conversations to 200 messages and history to 100 conversations. Context is refused when full, with guidance to start another conversation; none is silently omitted. There is no delete/export control in this increment. Existing chat output-token settings apply, with 15-second connect, 30-second idle and three-minute total request limits. An oversized or empty answer fails without publishing partial output.

The question is saved before inference. Offline/error/timeout leaves that saved question available for **Retry answer**, which does not append another copy of the question. **Stop** discards partial output, closes this app's connection and retains saved messages; it does not prove server inference stopped. Changing conversation is disabled during requests and unsaved-answer recovery. Save completion cannot be cancelled. Leaving Ask requires stopping a request or saving/discarding a completed unsaved answer.

A completed answer whose final save fails remains visible with **Retry saving**, which performs no new inference, and explicit **Discard unsaved answer**. Discard keeps the saved question. Unsaved recovery is held in the current screen's memory; forcibly closing the app can lose that answer. Raw transport/storage exceptions are not displayed. Failed preparation retains the composer text. Corrupt history is retained and blocks Ask writes without blocking unrelated project data. Concurrent stale writes are refused by the database transaction.

`AskConversation`, `AskController`, `AskStore` and `AskScreen` follow MVC. Production history is one versioned `studio.ask.v1` record in the existing transactional database, separate from `studio.chat.v1.<projectId>`. A conditional transaction publishes the full library atomically; no legacy project keys or schemas change. PreferenceRecords remains only an injected legacy/test adapter.

## Recorded validation — issue #328

The evidence directories `acceptance/2026-10-31-ask-native-fixture`, `acceptance/2026-10-31-ask-web-fixture` and `acceptance/2026-10-31-ask-live` retain separate identities, exact source file manifests, sanitized observations and collector reports. F17 now configures 32 cells, including three Ask cells. Existing reports and initial F17 acceptance remain historical; the new manifest does not promote them to current support. The inventory keeps separate observations rather than combining their identities.

- Injected controller/widget checks cover no-project use, follow-ups/project isolation, empty/oversized/context input, preparation/save failure, Stop/deadline/disposal, sanitized offline retry, final-save retry, corruption/concurrent writes and 320-pixel scaled keyboard/code layout.
- Real macOS disk database and actual Chrome IndexedDB checks create two conversations, reopen twice, preserve unrelated project chat, roll back a failed transaction and isolate corrupt Ask data. These are fixtures, not manual native/browser application interaction.
- Actual configured Qwen3.5-9B MLX/Metal smoke used existing offline weights: 4,846 ms, 278 incremental updates and 1,284 answer characters, with Future/Stream explanation, fenced code and exact saved-answer reopen. Model identity records existing JSON configuration/index metadata hashes; weights were not freshly rehashed. No semantic correctness certification, browser live inference or additional platform/device support is claimed. The owned runtime was stopped after the smoke.
- Formatter, analyzer, full default tests, web/macOS debug builds and acceptance collector/inventory checks are recorded in the PR and requirements ledger. Required CI and independent final-revision review remain merge gates. The opt-in live smoke skips by default and is run with `--dart-define=ASG_REAL_INFERENCE=true`.

This increment does not replace or launch the installed stable app, download models, install software, alter the development schedule, or enable repository execution/cloud tools.

Review #5722262274 found a 16-pixel selected-project toolbar overflow at 320 pixels. The corrected layout and regression also exposed and fixed a vertical composer overflow with enlarged text. Selected-project Ask access, all toolbar actions, code/save recovery and no-project entry now pass as real Chrome widget interactions and native fixtures. Updated fixture observations bind runtime source `3967d247f8984d2377961c0307e4446885f5ed28`; the earlier actual inference observation remains unchanged and historical. Only home/project view layout changed; Ask request/prompt/storage/model code is unchanged, so no new inference is claimed. Final local formatter/analyzer,908defaulttests/nineskips,15Chrome tests,41Python collector/inventory tests and web/macOS debug builds passed before corrected publication.


Completed Ask answers now retain the requested model ID and output-token ceiling
captured before saving their question. Changing settings affects later requests;
it does not relabel earlier answers or completed unsaved answers. Retry saving
retains that original metadata without inference. Legacy replies explicitly show
identity unavailable. Requested settings do not verify server-loaded weights or
revision. Metadata contains no endpoint and does not change Ask permissions.

## Conversation model connection

Use Conversation model connection to select a saved local connection preset for
one Ask conversation. The selected model and output ceiling appear above its
messages. Selection connects to the saved local endpoint on the next request; it
does not load weights, test compatibility or change global model settings.
Manage named presets in model settings, then use Refresh saved connection presets.

An existing conversation saves the choice before using it. A new conversation
saves its choice with the first question. A saved conversation retains a snapshot
when the original preset is edited or deleted. Choose Global model settings to
return that conversation to the current global configuration on every request.
New and legacy conversations default to global settings. Each completed reply
retains its own requested-model metadata independently of later selections.

Stop a request and save or discard a completed unsaved answer before switching.
If selection cannot be saved, the previous choice and messages remain. A selected
connection does not establish the server's loaded weights or verified support.
