# Agent engine

Persist an execution ID, task state, last verified checkpoint and audit events. The lifecycle moves through planning, approval, execution, verification and review. Pause, Stop, failure and recovery retain the last known result. After interruption, reconcile effects before retrying. Reuse the existing verification and repair journals for the first repository workflow.

See the [canonical requirements](../REQUIREMENTS.md#coding-engine-development-phase) for priority, dependencies and acceptance.

## CE01 restart reconciliation investigation — 18 November 2026

This is a prerequisite contract under #404, not an enabled automatic recovery
path. Existing candidate verification persists a dispatch ID and operation intent
before command launch. `CandidateVerificationStore` commits that journal with the
execution checkpoint. `NativeGenerationHost` keeps the active helper handle in
memory; `generation_command.py` starts the tool in an owned process group and
cleans that group on timeout, cancellation and parent loss. Neither handle nor
process-group identity is durably bound to a dispatch. The saved operation intent
therefore cannot prove whether a command started, exited or left descendants.

Evidence inspected: `lib/services/candidate_verification_store.dart`,
`lib/services/generation_host_native.dart`,
`lib/services/generation_process_capture.dart`, `tools/generation_command.py`
and `tools/test_generation_command.py`. The Mac helper suite ran 17 tests:
16 passed and one skipped. Its parent-loss test simulates changed parent identity;
it is not an application crash/restart acceptance test. Existing native database
fixtures establish record persistence, not surviving process identity.

### Required evidence boundary

A future trusted runner needs a versioned receipt bound to the exact task,
dispatch and operation, candidate source/approval identity, and host session.
Intent, launch observation, actual result and cleanup observation are distinct
facts. Receipts must retain unknown values rather than infer success from an
absent process. A PID or process-group number alone is insufficient: identifiers
can be reused, and a root exit does not prove descendant cleanup.

Runner-issued evidence must be outside candidate-writable scope, bounded and
validated before use. A random dispatch token binds records but is not by itself
authentication against a writer able to read or replace them. Cross-process
ownership and the trust of the receipt publisher need an explicit implementation
and adversarial tests before enabling automatic reconciliation. Do not introduce
a generic process killer or trust candidate output as a runner receipt.

Persist intent before launch; if persistence or authorization fails, launch
nothing. A separately observed launch must reference that intent. Publish a
validated actual result and the matching execution transition atomically with
the candidate journal. Accept only the expected dispatch/revision, source and
approval snapshots. An old completion cannot finish a newer attempt. Cleanup
failure remains an uncertain side effect even when an exit code is available.

| Observation after restart | Required behavior |
| --- | --- |
| Intent saved, no trustworthy launch or completion receipt | Keep interrupted; absence of launch evidence does not prove no launch. |
| Matching live runner identity established by a trusted ownership mechanism | Observe or cancel only through that mechanism; do not dispatch a duplicate. |
| Matching result and confirmed cleanup retained, journal completion absent | Validate the evidence and atomically reconcile once; refuse stale state. |
| Tool root exited, descendant cleanup unknown | Preserve actual root result separately; keep side effects unresolved. |
| PID reused, host session changed, receipt mismatched or corrupt | Preserve records and refuse automatic action against that process. |
| Cancellation recorded while result publication is uncertain | Retain cancellation intent and actual observations; do not fabricate an exit. |
| Completed journal and execution checkpoint | Display terminal evidence; never replay the dispatch. |

Current manual recovery stays explicit: the operator checks process cessation
and candidate changes, acknowledges the exact saved run, and grants fresh
verification consent. A linked run with missing execution evidence stays blocked
(PR #696). Unlinked legacy journals retain their existing manual acknowledgement;
they cannot acquire automatic recovery authority by migration.

### Next bounded implementation acceptance

Before process control, introduce a pure typed reconciliation decision model
with deterministic cases for every row above. It must consume validated evidence,
produce an explanation and conservative disposition, and have no process,
storage or networking effects. Missing evidence must remain unresolved; completed
and stale dispatches must never request replay. This model is a prerequisite, not
proof that a trusted receipt publisher or process ownership mechanism exists.

Subsequent runner integration needs disposable Mac fixtures for crash before
launch, crash after launch before receipt publication, lost result publication,
PID reuse, delayed old completion, corrupt receipts, cancellation during commit
and descendant cleanup failure. Assert no duplicate side effect, no signal to an
unowned process, unchanged last working output, and preserved unknown exits.
Real helper/app restart evidence must be recorded separately from simulated
identity and pure-model fixtures. Other platform acceptance remains deferred
under #400; no unavailable platform is verified by the Mac design.


### Actual helper parent-crash fixture — 18 November 2026

`test_actual_parent_exit_cancels_helper_and_cleans_descendant` starts a disposable
supervisor, the existing helper and a tool with a delayed-writing descendant.
After a launch handshake the supervisor calls `os._exit`, leaving the actual
helper parent relationship changed. The fixture observes cancellation, a
non-success helper result and absence of the descendant's delayed write. Process
lifetimes and waiting are bounded. The helper suite now runs 18 cases: 17 passed
and one skipped on this Mac. The four existing confinement cases also passed,
including private sibling file read/write refusal and inherited restrictions.

These are actual local helper/process fixtures, not Flutter app crash/restart
acceptance. The fixture-owned result file is not a production durable receipt
publisher and is not consumed by ASG recovery. At that fixture revision, app recovery still lacked a trusted publisher,
host-session binding and an atomic receipt-to-journal reconciliation path. Missing evidence remains unknown and cannot authorize replay.


## Confined candidate completion receipts — implementation under #404

The ordinary confined Flutter candidate workflow now prepares a receipt context
from the journal's saved dispatch before launching its helper. The optional host
contract leaves unsupported integrations and legacy records unchanged. Native
preparation creates a private directory beneath application support, outside the
candidate, SDK and package-cache roots. Context, intents and results remain local;
no record grants a command, retry, promotion or process-control permission.

The context binds the dispatch ID, recorded source and approval digests, stable
execution-input digest and a per-verification host-session nonce. Execution inputs
include the candidate directory, configured SDK/Python, confinement/protocol,
limits and approved task graph. Those are configured identities, not executable
binary provenance or current toolchain health. The nonce binds historical records;
it does not authenticate a currently running process after restart. A prepared
context cannot be applied to another verification snapshot.

The bundled helper's opt-in protocol is limited to ordinary confined resolve,
analyze, test and build operations. Named-test and offline-snapshot paths do not
inherit it. The caller supplies its PID for lineage checks before reservation
and at the tool launch boundary. This only refuses a lost caller; it is not a
saved-PID recovery or signalling mechanism. Already dispatched work may finish.

For each operation, the helper reserves an immutable intent before launch and
publishes the existing bounded command-result schema before stdout delivery.
Publication uses private, descriptor-relative files with no-follow opens,
exclusive atomic links and file/directory flushes. Existing intents or results
are never overwritten. Linked, overlapping, changed, oversized or malformed
metadata is refused. A missing result never proves that launch did not occur.
The launch-boundary parent check creates no synthetic exit when it refuses work.

Results retain the helper's existing normalized exit and cancellation/timeout/
output-limit flags. Cleanup is always recorded as unknown: neither an exit nor a
receipt proves descendant cessation. A nonzero helper transport exit does not
become a tool exit in the journal. Delivery failure preserves the interrupted
operation; a separately retained receipt may still be inspectable.

The native reader verifies the private directory, context, execution inputs,
operation and matching intent before exposing a result. Malformed file payloads
are redacted from parsing exceptions. Reopened history shows
receipts separately from saved check exits. It never inserts their results into
the journal or advances execution state. Errors preserve files and history;
late reads cannot update a disposed or superseded controller. Existing explicit
recovery, fresh verification consent and last-working protections remain in force.

The trust boundary is the existing inherited candidate confinement profile plus
app-private storage. It prevents a confined candidate from replacing the receipt
publisher's files. It does not protect against an unrestricted process acting as
the same user, and it is not a signed-helper or authenticated remote-worker design.
The [technical decision](TECHNICAL_DECISIONS.md#confined-candidate-completion-evidence--18-november-2026)
records this limit. Records are retained; this increment adds no automatic deletion
or archival/export promise for sidecar receipt files.

Evidence on this Mac: actual confined Flutter resolve and analyze completed and
were read through a new file reader; Flutter 3.47.6 revision
`5fc346839b5d0eef006ed8404392afb4dfae428d`, Dart 3.13.5 and Python 3.12.8.
Controlled helper tests exercise delivery failure, real parent death and broken
stdout, exclusive publication, parent mismatch, changed context and corrupt paths.
Widget tests cover separate receipt display at 320px/200% text and unchanged
unknown exits. This is not a full Flutter app crash/restart acceptance or a claim
that the whole generated four-operation graph passed in a real app. Inference was
not needed. Other platform acceptance remains deferred under #400.

Automatic receipt-to-journal reconciliation remains pending. It needs separately
verified cleanup/ownership evidence, atomic expected-revision checks, current
approval/input validation and actual app restart cases. The pure recovery model
must remain conservative when those inputs are absent.


### Disposable Flutter producer restart prerequisite — 18 November 2026

The receipt fixture launches a separate Flutter test process using the current
SDK with dependency resolution disabled. That process prepares the production
receipt directory and invokes the actual Python receipt publisher, then exits.
The parent waits for successful process completion before constructing a new
reader from a serialized interrupted run. It verifies the actual exit/output,
unknown cleanup, unchanged journal bytes and unchanged last-working sentinel.
The existing bounded helper supervises the disposable producer with a60-second
limit; the inner test has a20-second limit. No saved PID is signalled, no
verification retry is dispatched and no candidate is promoted.

This is an actual separate-process persistence fixture, not a GUI app crash or
restart test. The producer exits normally after publication. Crashes between
intent, launch, publication and journal commit, full app UI reopening and
automatic reconciliation remain separate acceptance under #404.


### Publisher crash after a tool side effect — 18 November 2026

The bounded fixture reserves a production completion intent, runs an actual
disposable Python tool that writes a candidate marker, then calls `os._exit(19)`
in the publisher before `publish`. The marker proves a side effect occurred;
there is no result receipt. A fresh reader using the persisted interrupted-run
JSON returns no completion, preserves the pending operation and journal bytes,
and leaves last-working output unchanged. Preparing the same dispatch again is
refused. No process-control, retry or reconciliation behavior is introduced.

This exercises the publication gap with an actual publisher exit, not a Flutter
GUI crash or a long-lived tool. An absent receipt cannot establish that dispatch
did not occur, nor supply a failed tool exit. Full app restart and cleanup/
ownership evidence remain separate requirements under #404.


### Mac app-restart isolation prerequisite — 18 November 2026

Native `main.dart` opens the default StudioDatabase before showing the app.
`database_factory_native.dart` uses application support for `studio-v2.db`;
StudioDatabase migration also reads legacy SharedPreferences. Completion
receipts default to the same support domain. The runner's bundle identifier is
`com.arsinha.asg.asg`. A second directory containing the same bundle must not be
assumed to have separate records. The installed path-provider macOS source
appends the bundle identifier to application-support paths; legacy preferences
use UserDefaults.standard. These observations establish configuration behavior,
not an executed app isolation test.

A disposable native restart fixture must first build into an exclusive output
directory with a distinct test bundle identifier and verify the resulting
Info.plist, executable and support/preference roots before opening storage. It
must preserve the stable app and owner processes. Use a test-only entrypoint
with explicit fixture project/candidate data and bounded phase handshakes so a
supervisor terminates only its live owned process, then relaunches the identical
test binary against its test records. Do not use an unrestricted environment
override of production storage roots or a stored PID as cancellation authority.
The existing project has no integration_test dependency; determine whether a
disposable entrypoint can provide the fixture without installing packages.

Acceptance needs observed interrupted history and retained receipt output after
actual application restart, unchanged last working output, no duplicate side
effect, and separate before/after source and app-binary identity. Receipt
cleanup remains unknown. Until the build identity, data-root isolation and
handshake harness are verified, full app crash/restart acceptance stays pending
under #404. This investigation launched no app and changed no owner data.

Build-settings observation on this Mac: `xcodebuild -showBuildSettings` with
workspace Runner, Debug configuration, disabled automatic package resolution,
an exclusive `/tmp/asg-404-isolation-derived` derived-data path and command-line
`PRODUCT_BUNDLE_IDENTIFIER=com.arsinha.asg.restartfixture` succeeded. Runner
reported that identifier and a target build directory under the exclusive
derived-data path. Product name remains Automated Software Generator.app;
therefore launch must use the explicit verified bundle path, never an app name
or the installed stable bundle. No tracked runner configuration changed.
This read-only configuration observation neither built nor launched a binary,
verified runtime data roots, nor established code-signing or restart behavior.

Next concrete implementation: a disposable test entrypoint and bounded host
harness using that separate bundle identity. Before allowing any record write,
the entrypoint must report and validate its actual bundle/support identity and
fixture paths; the host must verify the built Info.plist and keep phase
handshakes and owned process handles. Existing production storage defaults and
application identity must remain unchanged.


### Disposable native persistence probe — 18 November 2026

`tools/fixtures/native_restart_probe.dart` is a separate test entrypoint, never
called by production main. It reads the built bundle identifier before asking
for application support or preferences, requires exactly
`com.arsinha.asg.restartfixture`, and accepts only a canonical private temporary
control directory and bounded challenge. It then verifies the native support
directory identity, writes a nonce-specific test sentinel/preference, and exits.
A second launch checks both values without replacing them. Reports are
exclusive, nonce-bound and versioned. Errors do not reveal private record data.

`tools/native_restart_probe.py` inspects an explicit canonical bundle path and
hashes its files/links, refusing the stable identity, escaped executable and
external links. Inspection alone never launches. `--run` uses bounded live child
handles for two launches, verifies reports and unchanged bundle identity, then
reads only the nonce-specific key in the explicit fixture preference domain.
Artifacts remain available for inspection; it never builds, installs, downloads,
replaces the stable app, clears preferences or signals a stored PID. Six local
harness cases cover identity/path refusal, binary changes and handshake/domain
validation. These new host tests are run explicitly; existing required CI does
not automatically discover all new Python files.

On this Mac the first direct Xcode build lacked generated Flutter file lists.
The existing SDK's config-only command with `--no-pub`, Debug and the test target
created those ignored files without tracked runner edits. The subsequent build
used an exclusive temporary derived-data/output location, fixture identifier,
explicit test target, disabled automatic package resolution and disabled code
signing. It succeeded using existing local dependencies. The verified bundle
SHA256 was `93291aa7b514dc2b6fdd3064683fa37943617653a14ad0253564c54b43ab8d7f`.
The final host run completed two native launches of that unchanged bundle,
reported the fixture support directory and recovered the nonce preference. A
read of the explicit fixture defaults domain independently matched the nonce.

This is an actual native process persistence/isolation observation, not a
production StudioDatabase, candidate-history GUI or application crash test. No
inference, owner-record migration, package installation or stable app replacement
occurred. Next acceptance requires a bounded fixture of the actual interrupted
candidate history/receipt workflow using the verified isolated entrypoint, with
owned-process crash handshakes and unchanged last working output.


### Isolated native candidate crash/reopen — 18 November 2026

`tools/fixtures/native_candidate_crash.dart` uses the fixture bundle/private
control-root preflight, then opens the actual StudioDatabase in that isolated
support domain. It creates a fixed disposable Flutter source candidate and
seeded previous-working record/output. CandidateVerificationStore.start commits
the pending resolve journal, candidate and execution checkpoint atomically. The
fixture executes an actual confined offline Flutter resolve with the existing
SDK and production helper/receipt files. It deliberately does not commit the
returned result to the check journal. Only after durable journal/receipt and
before-state hashes are available does it report readiness for a host crash.

`tools/native_candidate_crash.py` checks the explicit bundle and unchanged hash,
starts the app with a private nonce-bound challenge, waits for the bounded
handshake, then SIGKILLs only the live Popen child it owns and reaps it. It
relaunches the same executable. The new app process reloads the actual journal
and production SourceCandidateController/SourceCandidateView with actions
disabled. The fixture expands the native widget tree and checks the pending
status and retained resolve exit text after frames render. This is a native
widget-tree observation, not a screenshot or manual navigation test.

Recovery assertions bind the same dispatch, pending operation and checkpoint;
compare journal/candidate/working-record bytes by hash, verify actual source
fingerprints and previous-working output, retain cleanup as unknown and refuse
promotion. No recovery acknowledgement, verification retry, inference or
automatic receipt-to-journal reconciliation is invoked. Five local host cases
exercise stale/unsafe reports, missing handshakes, linked reports, bundle refusal
and live-owned crash sequencing. These host tests run explicitly outside the
existing required CI discovery.

The disposable native build and exact final crash/reopen observation passed on
this Mac with existing dependencies and separate temporary outputs. Bundle
SHA256: `ab1545b3399c9d2fa43b83e420b6ec4eb1c46d0a83c5379560bf234c12669276`.
First seed validation correctly refused an empty working-source map; the fixture
was fixed to seed an actual source file/hash. A subsequent view assertion
required expanding all nested history sections; stage-only diagnostics avoid
logging record contents. The final binary was rebuilt and rerun after adding
current-source and post-render unchanged-state checks. Host handshakes bind the exact nonce-derived dispatch, not only its revision. No production source/runner edits, package installation,
stable app replacement or owner-process termination occurred.

This establishes a bounded actual native crash window after resolve receipt
publication and before journal completion. Full production-main navigation,
crashes at other lifecycle phases, all four fixed operations, cancellation during
commit and a generalized multi-tool recovery session remain pending under #404.
The seeded working output is a fixture sentinel, not a new generated-app
acceptance claim. Execution remains saved as executing with a pending operation;
reading it grants no new authority.


### Fixed verification completion-gap matrix — 18 November 2026

The isolated native fixture now accepts one fixed target operation or `--operation
all`. Protocol version2 reports the target, exact completed-operation prefix and
retained-receipt prefix. The entrypoint runs the production NativeGenerationHost
verifier with its existing test operation hook: each hook invokes the actual
confined runner, then pauses the selected successful result before returning it
to the verifier. Production progress callbacks persist all earlier steps and
the current pending operation through CandidateVerificationStore.checkpoint.
The fixture uses fixed disposable source, Flutter test and web scaffold; package
resolution stays offline against the existing SDK/cache. No model synthesis is
claimed.

| Crash target | Completed journal steps after reopen | Retained receipt prefix |
| --- | --- | --- |
| resolve | none | resolve |
| analyze | resolve | resolve, analyze |
| test | resolve, analyze | resolve, analyze, test |
| build | resolve, analyze, test | resolve, analyze, test, build |

All four cases passed on this Mac with the same disposable binary SHA256
`270b86f1dfc9d07466df00742dd140c9b15d60506d377ac432a83e7f0cfaed15`.
Each case used an actual app SIGKILL after its durable handshake and relaunched
the identical binary. The exact target receipt exit was zero, while the target
remained pending and the journal retained only earlier steps. Actual current
sources, journal/candidate/seeded-working records and working-output sentinel
remained unchanged before and after native view rendering. Cleanup remains
unknown, promotion unavailable, and no replay or reconciliation is invoked.
The host checks exact nonce-derived dispatch, operation/order, receipt prefix
and same binary across the matrix. Six explicit host tests include malformed
completed/receipt prefixes for every target. The earlier version1 resolve-only
observation remains tied to its own binary.

This covers four fixed successful completion-to-journal crash gaps in a
test-only isolated startup. It does not establish production-main navigation,
failed/cancelled operation recovery, cancellation during journal commit, all
earlier crash phases, trusted descendant cleanup or a generalized agent session.
Those remain pending under #404; other platforms stay deferred under #400.


### Candidate Stop intent persistence — 18 November 2026

SourceCandidateController now queues a typed Stop request with its current
CandidateVerificationStore session and immediately signals the host. An ordered
store queue prevents overlapping progress from racing the Stop record. The
write compares exact journal/candidate/execution state and binds the current
run, dispatch and stable inputs. Startup that never commits has no dispatch to
annotate. Failed subsequent startup cannot reuse a previous session identity;
stale writers and changed inputs refuse publication. Actual later exits remain
untouched, including failed results and successful results observed before a
late Stop. No execution phase is set to terminal cancelled on request alone.

The new version1 database namespace is independent of the existing journal and
checkpoint JSON. Corrupt bytes are preserved, parser payloads are redacted and
other records remain readable on native database reopen. Cached controller
history exposes retained Stop requests to the view without direct view storage
access. The view labels a saved request separately from actual exits/cleanup and
shows pending/save-error states. A save failure still signals the owned runtime;
missing intent after an uncommitted write remains unknown. Closing the view
does not discard an already requested observation write or notify it afterward.

Focused validation covers canonical input identity and malformed records;
ordered progress/Stop, immutable first request, stale session/input rejection,
failed startup and storage retry; actual native database close/reopen/corrupt
record preservation; responsive Stop during failed/pending writes and disposal;
late actual exits, signalling failure, and read-only reopened history display.
These deterministic/native-storage fixtures do not claim an actual user Stop
followed by a native app crash; that cancellation-window observation remains
separate from the already recorded successful-operation crash matrix.


### Native Stop crash fixture prerequisite — 18 November 2026

The existing completion-gap fixture owns CandidateVerificationStore.start and
passes checkpoints directly to NativeGenerationHost.verify. It therefore cannot
establish SourceCandidateController.cancel behavior. The next bounded case must
construct the production controller before verify and use its receipt preparation
and checkpoint callbacks. The existing operation override can call the actual
confined runner, retain a successful receipt, then hold before returning the
result. At that boundary invoke controller.cancel, wait for stopRequestSaving to
clear, reject stopRequestSaveError or absent/mismatched durable request, and only
then publish the crash handshake. Read the exact pending run from storage; do
not start a second store session. A second preparation correctly refuses an already reserved dispatch. The fixture
uses a nonce-specific receipt root and its sole controller-prepared directory;
it must never reserve the same dispatch twice.

The host kills only its own live disposable app handle. Reopen must verify the
request fingerprint, immutable record bytes and production view badge alongside
existing unchanged source/journal/working and receipt evidence. This chosen
boundary tests Stop after a real successful operation and before journal result
publication; it does not establish termination during a running command or
descendant cleanup. No new production hook is needed. Implementation and actual
native observation remain pending; existing six host contracts pass.


### Committed Stop intent with native app crash — 18 November 2026

The protocol3 disposable fixture accepts an explicit Stop case. It seeds a
nonce-specific project, board-mapped fixed Plan, saved conversation/approval and
real project input JSON, then runs SourceCandidateController.verify. The actual
confined runner uses the controller-prepared receipt directory in a nonce-specific
fixture root. After a real successful operation returns its retained receipt,
the override holds its result before journal publication, calls controller.cancel
and waits for its durable intent. A second reservation is deliberately avoided:
receipt preparation refuses duplicate dispatches. Missing/save-error/mismatched
intent refuses the crash handshake.

The host kills only its own live disposable app and relaunches the exact binary.
Reopen uses the production controller and expanded view with actions disabled.
It checks immutable Stop record bytes and matching run/input identity, the saved
Stop badge, actual receipt exits, pending journal and unchanged sources/working
output before and after rendering. No replay, reconciliation or promotion occurs;
cleanup remains unknown. The initial resolve Stop/crash/reopen passed with binary
SHA25642cac220434697802370236a862cd146469e71d1c72de1f08490b32b17ebb65c.

This case requests Stop after an actual successful tool result exists but before
its journal observation. It does not verify Stop during a still-running command,
a crash before intent commit, cancellation terminalization, descendant cleanup,
production-main navigation or general agent-session recovery. These remain
pending under #404; unavailable platforms stay under #400.

The complete Stop matrix subsequently passed for resolve/analyze/test/build on
the same SHA25642cac220434697802370236a862cd146469e71d1c72de1f08490b32b17ebb65c
binary: completed journal prefixes0/1/2/3 and receipt prefixes1/2/3/4 were retained,
Stop bytes matched, actual target exits remained zero, and pending execution
stayed executing with cleanup unknown. Evidence:
/tmp/asg-404-native-stop-matrix.json. Seven host contracts include missing Stop
and changed-intent refusal.


### Native Stop before intent commit — 18 November 2026

Protocol4 adds explicit `--stop --precommit` fault injection. A fixture-only
ConditionalRecordStorage decorator delegates native database reads and all
non-Stop writes, but holds the single Stop side-record transaction before
calling the database. The production controller still starts/checkpoints and
requests Stop. A fixture host records that its real cancellation method returned;
the crash handshake requires both this signal and the entered save barrier,
with saving still pending, no save error and no durable Stop row. The barrier
is never released; the host kills only the live disposable app handle.

Same-binary reopen uses the real database and production controller/view. It
requires the Stop row and badge to remain absent, while exact pending journal,
candidate, actual successful receipts, source files and seeded working output
remain unchanged before and after rendering. There is no invented cancellation
result, replay, promotion or cleanup confirmation. All four fixed operation
boundaries passed with binary SHA256
`fa890d17da510098278d629f21d49ce70a21dda31e8f9390f9aedd4e482bc916`.
Evidence: /tmp/asg-404-native-stop-precommit-matrix.json. Eight host contracts
reject missing signal/barrier and an unexpectedly saved request.

This explicitly demonstrates the documented precommit loss window with a
deterministic delay before transaction entry. It does not establish durability
of a transaction interrupted mid-commit, Stop during a still-running tool,
descendant cleanup, terminal cancelled execution or generalized CE01 acceptance.
Those remain pending under #404, with unavailable platforms under #400.


### Running-tool Stop prerequisite investigation — 18 November 2026

NativeGenerationHost owns _activeProcess and _activeCaptureCancellation per
instance. cancelVerification marks that instance cancelled, completes its capture
cancellation and signals its helper with SIGTERM. The current completion-gap
fixture invokes the real runner on a separate host and requests Stop only after
that runner returns, so its twelve cases cannot establish cancellation of a live
command. The next running-tool case must invoke runFlutterOperation on the same
verifier instance supplied to SourceCandidateController. The existing operation
override can start that future and await a bounded marker concurrently; no new
production hook or arbitrary command adapter is necessary.

A bounded fixture design is a fixed Flutter test which writes a nonce-bound
started marker under build/ then waits. build/ is excluded from source fingerprints,
so handshake data cannot masquerade as a source edit. Keep resolve/analyze
real and checkpointed, start the real confined test on the controller-owned host,
wait for the marker with a deadline, then call controller.cancel. Require the
committed Stop row to match the exact pending test dispatch. Await only bounded
real command settlement, retain any real receipt without fabricating a result if
completion delivery fails, and hold before the verifier publishes its result.
Crash/reopen must preserve pending test, prior steps, saved intent, sources and
working output, with no replay/promotion. Unexpected success, missing handshake,
wrong dispatch or any unbounded process must refuse evidence.

The capture cancellation path gives the helper three seconds to finish protocol
delivery; the supervisor attempts group SIGTERM, bounded root wait and SIGKILL,
then bounded reader completion. This can legitimately end with uncertain helper
completion delivery. NativeGenerationHost refuses nonzero helper completion when
receipt delivery is expected; it must not synthesize a cancelled tool exit from
that refusal. Sidecar receipts independently preserve actual results when present.
Their schema requires cleanup='unknown': process-group signals and root exit do
not establish arbitrary descendant cleanup.

Verification on this Mac: existing generation_command fixtures ran22 tests with
one skip (21 passed), including signal cancellation, parent loss, timeout and
exclusive retained completion evidence. Dart generation_process_capture_test
passed all5 tests, including cancellation interrupt and pipe/output limits. Logs:
/tmp/asg-404-running-tool-stop-command-tests.log and
/tmp/asg-404-running-tool-stop-capture-tests.log. These are deterministic helper
and capture tests, not actual native Flutter-test cancellation evidence. The
proposed running-tool native case and generalized CE01 acceptance remain pending
under #404; platform-specific unavailable acceptance remains under #400.
