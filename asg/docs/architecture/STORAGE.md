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

Conversation v1 evolves additively: old messages omit `planContext` and load as untyped history; new complete Plan replies carry the app-captured canonical project JSON. Existing role/content and preference keys stay unchanged. Reading and rewriting legacy messages preserves their original JSON shape; older readers ignore the optional field. No label parsing or legacy backfill grants approval eligibility. This is the migration strategy for this optional metadata.

`studio.planApproval.v1.<projectId>` stores the exact saved message index/content/context, explicit approval or withdrawal, and UTC recording time. The latest typed Plan reply and current project inputs must match before approval; the service rereads canonical metadata and durable chat before writing. New drafts or edited requirements make consent outdated. Approval is a local agreement record, not an executable plan, a source-modification permission, or a build trigger. The record tracks the latest decision, not a full approval audit history.

New keys are strictly validated and included in legacy migration if present. After migration, corrupt approval records are isolated like project application/generation records, retained verbatim and surfaced on the chat screen; approval actions cannot overwrite them. Chat remains readable. Successful actions publish only after persistence, failures can be retried, and busy/unsaved responses block overlap/navigation. Native and actual IndexedDB close/reopen tests cover approval retention and corrupt-record preservation. Like other repositories this uses the single-process session snapshot; cross-process/tab synchronization is not supplied.


## Structured requirements and tasks (F01)

`studio.requirements.v1.<projectId>` stores one atomic JSON record: schema version 1, monotonically increasing revision, requirements (stable ID, title, acceptance criteria), and development tasks (stable ID, requirement ID, title, dependency IDs, manual status). New production writes use RecordStorage/StudioDatabase. Native and web reopen validation preserves corrupt records and isolates them per project; existing project/chat/approval schemas remain unchanged. Same-session writers share a per-storage lock and reject stale snapshots; this does not provide multi-process editing.

Every successful board save invalidates earlier Plan approval conservatively, including task progress and edit/revert. Legacy metadata-only plan contexts remain current only until the first structured save. Plan requests capture the board revision before inference and include at most 12,000 characters of readable requirements with an explicit truncation label. Task Done is a manual progress record, never verification. Reopening a prerequisite or changing its scope reopens dependent tasks transitively.


Generated outcomes optionally retain an `approval` snapshot containing the exact Plan message index/content/context and approval timestamp. New app-led generation captures this identity before host generation and preserves it through verification progress and failures. Older records without the field still load and their verified previews remain available, but verification retry requires a new generated folder. Retry requires the exact current approval (including its timestamp) and matching exported input fingerprints; approving a replacement or reapproving the same draft cannot relabel an earlier source snapshot. Malformed or withdrawn provenance is rejected and retained as corruption. This additive field does not convert prose plans into executable tasks or verify requirements implementation.
