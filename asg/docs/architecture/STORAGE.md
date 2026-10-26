# Transactional storage and recovery

Production bootstrap opens one Sembast database per application isolate: `studio-v2.db` in the platform application-support directory, or `asg-studio-v2` in IndexedDB for the current browser origin. RecordStorage is injected behind the existing project, conversation, model, runtime, session and application repositories. In-memory session values change only after a successful transaction. PreferenceRecords/fromPreferences adapters support legacy fixtures; application bootstrap does not write preferences.

## Migration

At first startup all known Studio v1 keys are decoded and validated, then copied with a migration marker in one transaction. Existing database values win on retry. Original preference keys are retained untouched, including unrelated/future keys. Marker and copied data roll back together on an exception. Application definition/messages/revision are one atomic record; interaction writes retain the current chat history and revision number. A subsequent structural chat edit increments that revision.

Open uses strict DatabaseMode.create rather than Sembast's default neverFails recovery mode, which could replace corrupt data. Unreadable files, invalid migration/global schemas and malformed legacy data stop startup visibly. After migration, an unreadable application or generation record is retained verbatim and throws explicitly when that project record is accessed; unrelated projects can still open. There is no fallback starter or empty history for the damaged record. Other invalid global records still stop startup. Writes remain strictly validated before commit. There is no automatic destructive reset or fallback to an empty database. Keep the original preferences and database file when investigating errors. This increment does not provide a backup-export/restore UI; older app binaries read retained preferences and will not see post-migration database updates.

## Prototype interactions

Task items/completion, counter values and notes persist automatically. Writes serialize and coalesce rapid changes; chat waits for any pending interaction writes before generating a new revision. The preview is disabled during generation so focused keyboard input cannot be silently dropped. Save failures preserve the committed snapshot, show unsaved status and offer Retry saving preview. Navigation/project switching is blocked while busy, saving or unsaved. OS termination before a write completes can still lose the latest uncommitted input; no successful save is claimed before commit.

Task completion is an optional backwards-compatible element field; old definitions default to no completed tasks. Removing a task reindexes remaining completion markers. Notes controllers remain stable across saves; switching an element's type initializes the corresponding state.

## Coverage and limits

Tests exercise all legacy namespaces, retained originals, migration interruption/rollback/retry, malformed preferences/database records, physical-file corruption preservation, failed writes, reopen persistence, interaction failures/retry, rapid writes, generation ordering, kind changes, disabled keyboard input and navigation while saving. A dedicated Chrome test uses actual IndexedDB and runs in CI. Native macOS/Android and web builds validate platform imports.

Native Sembast is intended for a single app isolate/process; do not concurrently open the same file in another process or isolate. Repositories use a session snapshot; another tab's changes are visible after reopening, not live synchronized in the UI. Browser storage is origin/port-specific and can be cleared by the browser. This is unencrypted local application storage, not a credentials vault. Sembast loads records into memory; large histories will need pagination/retention and further storage evaluation.

## Plan approval records — issue #28

Conversation v1 evolves additively: old messages omit `planContext` and load as untyped history; new complete Plan replies carry app-captured context (project, requirements revision and prototype revision/definition). Existing role/content and preference keys stay unchanged. Reading and rewriting legacy messages preserves their original JSON shape; older readers ignore the optional field. No label parsing or legacy backfill grants approval eligibility. This is the migration strategy for this optional metadata.

`studio.planApproval.v1.<projectId>` stores the exact saved message index/content/context, explicit approval or withdrawal, and UTC recording time. The latest typed Plan reply and current project inputs must match before approval; the service rereads canonical metadata and durable chat before writing. New drafts or edited requirements make consent outdated. Approval is a local agreement record, not an executable plan, a source-modification permission, or a build trigger. The record tracks the latest decision, not a full approval audit history.

New keys are strictly validated and included in legacy migration if present. After migration, corrupt approval records are isolated like project application/generation records, retained verbatim and surfaced on the chat screen; approval actions cannot overwrite them. Chat remains readable. Successful actions publish only after persistence, failures can be retried, and busy/unsaved responses block overlap/navigation. Native and actual IndexedDB close/reopen tests cover approval retention and corrupt-record preservation. Like other repositories this uses the single-process session snapshot; cross-process/tab synchronization is not supplied.


## Structured requirements and tasks (F01)

`studio.requirements.v1.<projectId>` stores one atomic JSON record: schema version 1, monotonically increasing revision, requirements (stable ID, title, acceptance criteria), and development tasks (stable ID, requirement ID, title, dependency IDs, manual status). New production writes use RecordStorage/StudioDatabase. Native and web reopen validation preserves corrupt records and isolates them per project; existing project/chat/approval schemas remain unchanged. Same-session writers share a per-storage lock and reject stale snapshots; this does not provide multi-process editing.

Every successful board save invalidates earlier Plan approval conservatively, including task progress and edit/revert. Legacy metadata-only Plan contexts remain readable but require a fresh draft under the prototype-bound context introduced in issue #50. Plan requests capture the board revision before inference and require the complete readable requirements/task document within 12,000 Dart string code units. Oversized Plans fail before conversation writes or provider creation; shorten structured text and draft again. Approval and Build also reject oversized contexts, including previously saved drafts; withdrawal and history remain available. Discuss and advisory Review retain explicitly labeled truncation at the same budget. Task Done is a manual progress record, never verification. Reopening a prerequisite or changing its scope reopens dependent tasks transitively.


Generated outcomes optionally retain an `approval` snapshot containing the exact Plan message index/content/context and approval timestamp. New app-led generation captures this identity before host generation and preserves it through verification progress and failures. Older records without the field still load and their verified previews remain available, but verification retry requires a new generated folder. Retry requires the exact current approval (including its timestamp) and matching exported input fingerprints; approving a replacement or reapproving the same draft cannot relabel an earlier source snapshot. Malformed or withdrawn provenance is rejected and retained as corruption. This additive field does not convert prose plans into executable tasks or verify requirements implementation.


## Fixed starter task graph (F02, issue #40)

New generated outcomes add `tasks`, a canonical four-task graph (`starter-resolve`, `starter-analyze`, `starter-test`, `starter-build`) with allowlisted operation names and linear prerequisite IDs. The containing outcome's exact approved Plan snapshot binds the graph to its requirements context. Malformed IDs, order, operations, dependencies or missing/withdrawn approval fail closed. Legacy outcomes without tasks remain readable; they are not assigned invented structured provenance. No storage key or existing field changes.

Task status is derived from saved command exit results and generation phase. Downstream results after a failed/timed-out prerequisite are rejected. A verifying record reopened without active verification displays interrupted, not running. A host/preparation failure before task verification blocks pending tasks and retains the outcome error. Per-task source/dependency validation refusals and operation runner exceptions save optional `failedOperation` (resolve/analyze/test/build), identifying the next task as failed without inventing a command exit result. It is accepted only in failed phase after successful preceding steps; downstream tasks remain blocked. Legacy records omit it. A new verification attempt clears it before publishing progress. This adapter verifies the fixed starter; it does not translate arbitrary Plan prose or establish requirements implementation. Retry reruns verification under existing consent and provenance checks; resumable action checkpoints remain F03.


## Structured Plan contracts (F02, issue #42)

The saved Plan message may contain one standalone fenced `asg-build` JSON object: version 1, adapter `flutter-starter`, and the canonical four-task graph documented above. It is validated from the exact durable approved content before either generation or verification retry. Maximum Plan content is 65,536 characters; unknown fields/versions/adapters, invalid graphs and ambiguous blocks are rejected before host work. The parsed graph is persisted in the existing outcome `tasks` field and bound to the existing exact approval snapshot; no storage migration/key changes. Legacy prose approvals and outcomes remain readable and previews available, but a fresh structured draft/approval is needed to start Build. The contract requests only fixed starter creation/verification and cannot authorize model source edits. General Plan conversion remains pending.


## Prototype-bound Plan context — issue #50

New `planContext` strings contain project metadata, requirements revision, validated prototype definition and prototype revision. An absent saved application uses the deterministic starter/revision fallback. Any later definition or revision change makes approval outdated, including an edit/revert; unreadable application evidence fails closed. Legacy contexts remain readable but cannot match the new execution boundary: request and approve a fresh Plan. No stored record keys or shapes change and no legacy backfill grants approval. Build also compares its captured definition with the current saved prototype before any host work and after asynchronous preparation. Discuss and advisory Review do not require a readable approval context.

## General task proposals — issue #46

A saved current Plan may carry one bounded version-1 `asg-tasks` proposal (up to 200 queued tasks). Explicit additive import validates requirement references, IDs and acyclic dependencies, rejects unknown fields/status/commands and duplicate JSON members, and rereads exact current durable Plan/project/board evidence. Atomic board save preserves existing tasks, increments revision and invalidates prior approval. This creates planning records, never executable commands or verified completion.


## Output-limit evidence — F03, issue #70

Generation steps add optional `outputLimitExceeded` (legacy records default false). Success now requires zero exit, no timeout and no output exhaustion. Failed output-limit outcomes survive reopen, block downstream task/board verification, and cannot be saved as Ready or followed by fabricated downstream success. The fixed helper enforces 65,536 combined output bytes with process-group cleanup; the UI identifies the limit explicitly. No record keys change. This is the output-limit increment only; resumable action checkpoints and user stop/cancel remain F03 work.


### Verification dispatch checkpoint (F03, issue #76)

Generated snapshots optionally store `pendingOperation` (`resolve`, `analyze`, `test` or `build`). Missing fields retain the legacy empty default. The native host awaits persistence at the final dispatch boundary before starting a helper. A marker means the command may have started, never that it succeeded. A command result clears the marker in the same saved snapshot that adds its step; exceptions retain uncertainty and completed results. Readers reject markers inconsistent with phase or the next task in the saved graph. The checkpoint carries the snapshot's existing approval, graph and input fingerprints. It does not grant replay authority: explicit Retry still restarts all checks and automatic checkpoint resume remains unavailable.


## F04 candidate evidence and atomic promotion

`studio.sourceCandidate.v1.<projectId>` uses the generated-project schema for candidate-only pending-operation checkpoints, actual results and failures. It never replaces `studio.generation.v1.<projectId>` during verification. `confinementVersion: 1` is additive; unknown versions fail closed. Omitted legacy fields retain trusted-starter behavior. The marker survives copies/reopen and forces future candidate/promoted-snapshot checks through the confined native runner. Candidate/previous record corruption is retained and isolated like working-generation corruption.

Promotion uses ConditionalRecordStorage.commitRecords (implemented by StudioDatabase) for one Sembast transaction: compare exact expected working/project/prototype/board/chat/approval strings, run the final synchronous authorization guard, then write the verified working record and `studio.generationPrevious.v1.<projectId>` backup together. A mismatch, guard exception or failed transaction publishes neither pointer. The session cache updates only after commit. The previous folder is never deleted or overwritten. Operation cancellation is locked during this final publication; consent revocation serialized after a successful commit applies to future operations. A previous pointer is retained metadata, not a complete F06 history/rollback UI. Test adapters without atomic conditional writes cannot promote.


## F05 candidate verification journal

`studio.candidateChecks.v1.<projectId>` is an additive version-1 journal of manual candidate verification runs. Each sequential run stores UTC start time, an immutable generated-project snapshot (including exact approval/tasks/input fingerprints, operation results and pending marker), and an explicit finished flag. A run is reserved before host verification, then each checkpoint and the latest `studio.sourceCandidate.v1.<projectId>` value commit atomically with expected-value comparison. Failed persistence blocks downstream commands; a superseded writer cannot overwrite another session. Available exit observations can still be saved after late Stop or withdrawal without authorizing further execution. Process loss/disposal may leave an unfinished/pending run; no exit or success is invented.

Prior run snapshots are retained across manual retries. History begins with new runs, without fabricating old overwritten evidence. All runs are retained; there is no permanent per-project check ceiling or silent pruning/reset. Full history pagination/export remains future F06/F08 work. Corruption is preserved and isolated to the affected record; verification fails closed. Nontransactional test/legacy adapters cannot start checks. Viewing saved history never replays commands or grants promotion. These are verification runs, not automatic repair attempts, per-category budgets or F06 rollback/history completion. Model repairs and their three-attempt category budget remain F05 work.


Build outcome history (F06 issue104): generation/candidate records add `buildHistoryVersion: 1` and `buildHistory`, a sequence of terminal ready/failed snapshots with UTC `recordedAt` and a full validated GeneratedProject. Current snapshot and history publish in one record write; working-candidate promotion uses its existing conditional multi-record transaction. Identical repeated terminal publication is deduplicated; a new verifying-to-terminal transition retains a separate outcome even when its content matches. Legacy terminal snapshots are retained on the next save with null timestamp, displayed as unknown. No history/artifact pruning occurs. Recorded artifact hashes/paths are evidence, not live existence claims; opening preview continues existing validation. Rollback remains pending under F06.


## Imported folder requirements workspaces

`studio.inspectedFolders.v1` retains explicitly saved folder references. Inspection and workspace entry reread current files without commands or source writes. Requirements and tasks use the existing validated requirements schema at `studio.requirements.v1.imported-<SHA256>`, hashing UTF-8 canonical root text from the inspector. This namespace is separate from generated project IDs. Folder moves/renames start separate records; no automatic merge/migration is attempted. References and boards are application database records, not files in the imported folder. Current integration grants no source-write/execution approval and does not create a generated prototype. Imported Plan context/approval remains pending.
