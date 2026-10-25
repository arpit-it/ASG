# Transactional storage and recovery

Production bootstrap opens one Sembast database per application isolate: `studio-v2.db` in the platform application-support directory, or `asg-studio-v2` in IndexedDB for the current browser origin. RecordStorage is injected behind the existing project, conversation, model, runtime, session and application repositories. In-memory session values change only after a successful transaction. PreferenceRecords/fromPreferences adapters support legacy fixtures; application bootstrap does not write preferences.

## Migration

At first startup all known Studio v1 keys are decoded and validated, then copied with a migration marker in one transaction. Existing database values win on retry. Original preference keys are retained untouched, including unrelated/future keys. Marker and copied data roll back together on an exception. Application definition/messages/revision are one atomic record; interaction writes retain the current chat history and revision number. A subsequent structural chat edit increments that revision.

Open uses strict DatabaseMode.create rather than Sembast's default neverFails recovery mode, which could replace corrupt data. Unreadable files, malformed records and invalid schemas stop startup visibly. There is no automatic destructive reset or fallback to an empty database. Keep the original preferences and database file when investigating errors. This increment does not provide a backup-export/restore UI; older app binaries read retained preferences and will not see post-migration database updates.

## Prototype interactions

Task items/completion, counter values and notes persist automatically. Writes serialize and coalesce rapid changes; chat waits for any pending interaction writes before generating a new revision. The preview is disabled during generation so focused keyboard input cannot be silently dropped. Save failures preserve the committed snapshot, show unsaved status and offer Retry saving preview. Navigation/project switching is blocked while busy, saving or unsaved. OS termination before a write completes can still lose the latest uncommitted input; no successful save is claimed before commit.

Task completion is an optional backwards-compatible element field; old definitions default to no completed tasks. Removing a task reindexes remaining completion markers. Notes controllers remain stable across saves; switching an element's type initializes the corresponding state.

## Coverage and limits

Tests exercise all legacy namespaces, retained originals, migration interruption/rollback/retry, malformed preferences/database records, physical-file corruption preservation, failed writes, reopen persistence, interaction failures/retry, rapid writes, generation ordering, kind changes, disabled keyboard input and navigation while saving. A dedicated Chrome test uses actual IndexedDB and runs in CI. Native macOS/Android and web builds validate platform imports.

Native Sembast is intended for a single app isolate/process; do not concurrently open the same file in another process or isolate. Repositories use a session snapshot; another tab's changes are visible after reopening, not live synchronized in the UI. Browser storage is origin/port-specific and can be cleared by the browser. This is unencrypted local application storage, not a credentials vault. Sembast loads records into memory; large histories will need pagination/retention and further storage evaluation.
