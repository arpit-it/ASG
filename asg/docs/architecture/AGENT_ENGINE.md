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


### Actual native running-test Stop — 18 November 2026

Protocol5 adds `--operation test --stop --running`; other operation/precommit
combinations are refused. A fixed confined Flutter test creates a nonce-bound
marker under build/ and waits, with a bounded failure deadline. The same verifier
instance passed to SourceCandidateController starts the actual test runner,
waits for that marker, calls controller.cancel and waits at most12 seconds for
settlement. The marker is excluded from source fingerprints; source JSON and
approval/task mappings remain bound to the same disposable project.

The crash handshake requires real Stop signalling, a committed matching intent,
prior successful resolve/analyze steps and an actual cancelled test receipt with
nonzero exit. Missing/uncertain completion delivery refuses this case; it never
fabricates a result. The operation override holds before journal publication,
then the host crashes only its live disposable app and reopens the same binary.
Production controller and expanded read-only view retain the Stop badge and
actual cancelled receipt, while the journal still has test pending and the
execution remains executing. Sources, candidate/journal and seeded working
output remain unchanged before and after rendering; no replay or promotion.

The actual native running-test case passed on this Mac using binary SHA256
`608d3d1f2106cf18c49898025042effce773a0c248bf025f022f8cd8bf8b1b0a`.
The retained test result was exit-1/cancelled=true, preceded by real successful
resolve/analyze receipts. Evidence:
/tmp/asg-404-native-running-stop-observation.json. Nine host contracts include
missing live marker and unexpected successful/non-cancelled result refusals.

This establishes one fixed test cancellation with real retained completion
evidence before an app crash. Cleanup remains unknown; it does not prove
arbitrary descendant cleanup, uncertain-delivery native recovery, cancellation
during every operation, interruption inside a database commit, production-main
navigation or generalized CE01 completion. These remain pending under #404;
unavailable platforms stay deferred under #400.


### Native uncertain test completion delivery — 18 November 2026

Protocol6 adds `--operation test --stop --running --uncertain`. A fixture-only
asset loader requires exactly one helper `receipt.publish(result)` anchor and
injects a test-only nonce marker followed by process exit73 immediately before
that publication. Resolve/analyze and the production helper/allowlist remain
unchanged. The actual confined test starts and receives Stop through the same
controller-owned host; the publication marker proves the intended failure point
was reached. A returned target GenerationStep or unexpected result file refuses
this case rather than overriding real evidence.

Before the owned app crash, the fixture requires committed exact Stop intent,
prior successful resolve/analyze receipts, target intent bound to the same
receipt context/dispatch and no target result. Same-binary reopen hashes the
exact target intent before/after native view rendering, requires the result to
stay absent and verifies that no target result label or fabricated exit appears.
Pending test, earlier steps, sources and working output remain unchanged;
execution stays executing and cleanup stays unknown. The report's null exit
and false cancellation-confirmation flag mean missing retained evidence, not
proof of a particular tool outcome. No retry/reconciliation/promotion occurs.

The actual native case passed on binary SHA256
`85e6371327604eb5b1c9f2ba1152222dddf41767bdf3d991a93a9d29f1edb0b7`.
Evidence: /tmp/asg-404-native-uncertain-observation.json. Ten host contracts
include invented exit/cancellation, unexpected target receipt and changed-intent
refusals. This is deterministic helper publication failure after a real test Stop,
followed by app crash/reopen; it does not establish all transport failures, every
operation's cancellation, arbitrary descendant cleanup, mid-commit durability,
production-main navigation or generalized CE01 completion. These remain pending
under #404; unavailable platforms remain deferred under #400.


### Read-only interrupted-candidate recovery summary — 18 November 2026

CandidateRecoveryStatus describes each unfinished fixed operation with a pending
dispatch. It distinguishes unavailable/changed execution identity, loading
completion evidence, unreadable or mismatched evidence, no retained target exit,
and an actual retained target exit with runner activity and cleanup still unknown.
A matching saved Stop is stated separately as intent; unreadable Stop evidence
stays explicit. Finished/no-pending rows receive no interrupted-run summary.

The pure model compares dispatch plus saved source, approval and execution-input
fingerprints against every returned receipt and refuses duplicate target results.
An earlier operation's receipt cannot supply the pending operation's exit. The
controller only describes a current matching history row, tracks receipt refresh
loading separately from an empty result and suppresses cached exits if the saved
journal later becomes unreadable. Epoch/disposal guards still own async refresh.
A native parity test compares the projection with actual CandidateReceiptFiles
preparation, preventing a self-confirming test fixture from masking divergence.

SourceCandidateView renders the explanation beside existing detailed saved
execution/Stop/receipt evidence. Viewing it performs no writes or commands and
adds no recovery/retry controls. Existing explicit acknowledgement and fresh
verification consent remain required. No stored formats/keys change. This model
does not authenticate publishers, verify process ownership or cleanup, or invoke
the future AgentRecoveryDecision resultReady path. It is a bounded per-run
interface improvement, not generalized session/reconciliation acceptance.

Focused coverage includes pure identity/outcome distinctions, native receipt
projection parity, delayed refresh, stale-input refusal, unreadable-history
preservation and a320px/2x-text read-only view. General CE01 remains open under
#404 and unavailable platform acceptance remains deferred under #400.


### Recovery confirmation evidence — 18 November 2026

Resolve interrupted verification now captures the exact selected run's read-only
recovery summary when opening confirmation. A retained actual exit is described
as retained evidence with unknown runner cleanup; missing or unavailable
completion remains unknown. The dialog no longer unconditionally calls every
exit unknown. Process cessation and candidate changes still require explicit
operator inspection, and confirmation still uses the expected run through the
existing stale-dispatch/journal guards. Dismissal performs no write; successful
acknowledgement still clears verification consent. No summary grants authority.

The dialog scrolls its title/content together so inspection text and actions stay
usable at320px with2x text. Three widget cases cover retained, missing and
unavailable evidence, intent-only Stop wording and byte-for-byte dismissal
preservation. Existing stale-confirmation and fresh-consent regressions remain
mandatory. This is component-level UI coverage, not production-main navigation
or generalized CE01 acceptance.


### Durable operator recovery acknowledgement — 18 November 2026

Explicit interrupted-candidate acknowledgement now adds an immutable
`studio.candidateRecovery.v1.<dispatch>` side record in the same conditional
transaction as the existing journal closure and linked execution transition to
awaiting approval. Its version1 payload binds project, run number, dispatch,
original start time, UTC action time and before/after typed-run fingerprints.
Current journal/checkpoint/candidate formats are unchanged. The after fingerprint
requires the exact existing failed/finished acknowledgement result, retaining
pending operation and real steps rather than inventing an exit.

An existing side record, stale journal/execution, missing execution or failed
transaction leaves prior journal/checkpoint/evidence intact; the side record is
never overwritten by this action. Legacy unlinked runs preserve their existing
explicit acknowledgement behavior without inventing a dispatch-bound audit row.
Native database validation binds the record key to dispatch and isolates corrupt
records while preserving their bytes. Typed parsing redacts invalid JSON source.

Reopened candidate history shows the saved operator action/time separately from
retained command exits and Stop intent. Its label says the action does not
confirm command exit or cleanup. Unreadable acknowledgement evidence is shown
without blocking valid history or replacing the record. Existing process/change
inspection, stale-dialog checks and fresh verification consent remain unchanged;
no action record authenticates an operator or authorizes replay/process control.

Coverage includes exact transition/identity and malformed metadata, atomic failed
and existing-record refusal, duplicate acknowledgement preservation, real native
Sembast close/reopen plus corruption isolation, legacy absence, reopened view
non-mutation and fresh consent. The isolated native target builds, but new audit
acceptance is database/controller/widget evidence, not a fresh native app-crash
or production-main navigation observation. Generalized CE01 remains open under
#404 and unavailable-platform acceptance remains under #400.


### Native acknowledgement and third launch — 18 November 2026

Protocol7 adds `--operation test --stop --running --acknowledge` for the fixed
actual-cancellation fixture. The first app is crashed only after real cancellation
and committed Stop evidence. The second app verifies unchanged interrupted state
and rendered evidence, then explicitly invokes production controller
acknowledgeStopped as a fixture action. It requires the exact new action record,
a closed journal and awaitingApproval execution, while preserving sources and
working output. A separate flushed after-ack baseline records the action,
execution and journal hashes. The second report distinguishes read/paint
observations from its subsequent acknowledgement transition.

The third process launches the identical binary and verifies exact action and
execution bytes against that baseline. It retains the prior Stop and actual
cancelled receipt, displays the saved acknowledgement in the actual expanded
production view and checks its real checkbox/button widgets with actions enabled:
consent is false and verification disabled. One saved run and awaitingApproval
remain; no new dispatch/replay/promotion occurs. Sources, candidate record, seeded
working output and all read-only state remain unchanged. Only the first owned
live process handle is deliberately crashed; later apps exit normally.

The actual three-launch observation passed on this Mac with binary SHA256
`0a2eb178c7902ea1bcf81a0794ad59dacee2dbeb6162adde6fc9f8989d22105f`.
Evidence: /tmp/asg-404-native-ack-reopen-observation.json. Eleven host contracts
include changed action/state, reused consent and new-dispatch refusals. This is
fixture-driven controller acknowledgement after bounded owned-process evidence,
not a human process-inspection claim, authenticated operator, verified arbitrary
descendant cleanup, production-main navigation or generalized CE01 acceptance.
Cleanup remains unknown and those broader limits stay pending under #404/#400.


### Native explicitly consented retry — 18 November 2026

Protocol8 adds `--retry` to the fixed running-test acknowledgement mode. On
launch three, the actual view initially has unchecked consent and disabled
verification. The fixture explicitly invokes the checkbox callback, then the
enabled production Verify callback. Only then does it create an excluded-build,
nonce-bound permit for the original fixed waiting test; source bytes stay equal.
The distinct second dispatch completes real resolve/analyze/test/build. A fourth
identical-binary launch verifies its exact saved run/execution, successful actual
receipts and build outputs, with consent unchecked again and exactly two runs.
The first run's immutable acknowledgement, Stop and cancelled receipt remain;
working pointer/output stay unchanged, and promotion is never invoked.

The actual four-launch observation passed with binary SHA256
`bcc0bd3c00405b8c1a511c86b07d78b38ca268f4c732e2aab70e9af01d8f0659`;
evidence /tmp/asg-404-native-retry-final-regression.json. Twelve host contracts pass.
This fixed fixture continuation does not establish human process inspection,
arbitrary cleanup, production-main navigation or full CE01/general synthesis.


### Retry promotion boundary investigation — 18 November 2026

PR718 establishes a successful second verification and restart, but deliberately
injects a publication callback that throws. Its previous-output fixture is a
seeded file/record, not an actual verified working preview. Existing controller
coverage passed all44 tests in /tmp/asg-404-retry-promotion-controller.log:
separate retry rows, preview failure, atomic save failure preserving the old
pointer and verifying checkpoint, concurrent approval refusal and live-host reuse
refusal. Those tests use controlled hosts; they do not cover this native app flow.

Production SourceGenerationController.promoteCandidate requires a separate ready
confined candidate and host, exact expected working record and current approval.
It starts a separately validated preview, then atomically updates working and
previous pointers together with only the latest matching execution's transition
from verifying through reviewing to completed. Failure stops the candidate preview;
success transfers host ownership and releases the previous host. Native preview
rechecks source/build fingerprints and binds a tokenized loopback ephemeral port.

A next bounded fixture should use that production publication action and real
NativeGenerationHost in the isolated fixture namespace, explicitly promote only
after the second run passes, inspect pointer/previous record and completed second
checkpoint, preserve first action/Stop/cancelled evidence, then restart identical
binary to prove no dispatch or promotion replay. It must identify seeded previous
output honestly, and separately cover a refused publication preserving the old
pointer/checkpoint. The preview port/host is an exclusive fixture-owned resource;
never use the owner's stable app or output. This investigation changes no runtime
behavior and does not establish actual promotion acceptance or general CE01.


### Native retry promotion and fifth launch — 18 November 2026

Protocol9 adds `--promote` to the fixed retry mode. Fourth launch first verifies
unchanged history/output on read and render. It explicitly invokes production
SourceCandidateController.promote and SourceGenerationController.promoteCandidate
with a separate real NativeGenerationHost. A fixture storage wrapper refuses the
first publication before its atomic transaction, after native preview validation;
working/previous pointers and the verifying second execution remain exact. This
is a precommit refusal, not a midtransaction crash/durability claim.

The next explicit attempt permits the real database transaction. It verifies the
working record equals the ready second-run candidate, the previous record equals
the seeded old record, only the second execution is completed, and the first
acknowledgement/Stop/cancelled evidence, candidate journal and source stay intact.
An actual bounded HTTP request to the tokenized loopback preview returns200 HTML.
The fixture records separate post-promotion hashes and closes its owned hosts.
Fifth identical-binary launch checks exact working/previous/execution bytes,
actual second-run receipts/build fingerprints, both histories and unchecked fresh
consent. Read/render creates no dispatch or promotion. The report's unchanged
read/render fields refer to the checks before explicit actions; promotion fields
record the later publication separately.

Actual five-launch observation passed on this Mac, binary SHA256
`e7dcbc435607182cbbde0c083bce3fd559616c9c0f68a708c28cf7a74f96c493`;
evidence /tmp/asg-404-native-promotion-observation.json. Thirteen strict host
contracts pass. Previous output is seeded, not a previously verified live preview.
This remains fixture-controller acceptance, not production-main navigation,
human process inspection, arbitrary cleanup, generalized synthesis or full CE01.


### Native promotion committed before confirmation — 18 November 2026

Protocol10 adds `--promotion-crash` to the fixed promotion mode. Its fixture-only
storage wrapper first awaits the real atomic database transaction, then invokes
an after-publication hook before returning to SourceGenerationController. The
hook requires the exact new working/previous records and completed second
execution, unchanged first acknowledgement/Stop/history/source and old output.
The candidate controller must still be busy/promoting, with promoted false and
no delivered preview. It flushes the post-commit baseline and nonce-bound report,
then waits. The host validates that report and crashes only its fourth Popen app
handle, in addition to the existing first-run crash; no saved PID is used.

Fifth identical-binary launch verifies the exact committed pointers and execution,
actual receipts/build output, both histories and fresh unchecked consent without
new dispatch or promotion. This is after-commit/before-controller-confirmation
acceptance, not a crash inside a transaction, delivered UI success or evidence
that arbitrary descendants were cleaned up. The crash mode does not claim the
post-success HTTP check performed by the separate normal-promotion case. Seeded
previous output, production-main navigation and broader CE01 limits still apply.

The actual crash/reopen observation passed on this Mac, binary SHA256
`c7145ffb97f58cf4e3f7479c34ffab8d9a69fc511e7664888bfc5ff403bcd963`;
evidence /tmp/asg-404-native-commit-crash-observation.json. Fourteen host contracts
include precommit/not-ready, already-delivered controller success and missing
refusal-preservation report rejections. The unchanged read/render report fields
refer to the observations before explicit actions; the commit-gap report records
the subsequent committed-but-unconfirmed boundary separately.


### Persistent session boundary investigation — 18 November 2026

The accepted native candidate lifecycle does not persist a multi-task session.
AgentExecutionCheckpoint stores only taskId/revision/phase. CandidateVerificationStore
creates a new candidate-project-run execution for each verification and atomically
binds that individual run. RequirementsBoard persists task/dependency/status data,
but it is authored project planning data rather than an execution-session ledger.
SourceReviewController has durable repair-category budgets, yet active-loop,
cancellation and current candidate ownership are controller-local. These existing
records must not be relabelled as a resumed multi-task agent session.

Nineteen focused checkpoint/journal tests passed in
/tmp/asg-404-session-investigation-tests.log, including native completed checkpoint
reopen/replay refusal and stopped/uncertain journal corruption isolation. They
verify the existing per-dispatch boundary only. StudioDatabase explicitly validates
and isolates execution/recovery record prefixes; a session namespace would need
its own validator and close/reopen tests, not merely a generic string write.

The next bounded implementation should add a typed immutable session envelope
and conditional storage, with its own version/revision and project/session IDs,
exact approved-plan snapshot, frozen selected task/dependency membership and
references to existing candidate task/dispatch identities. Validate duplicate or
unknown members, dependency cycles and mismatched task/dispatch/project bindings;
apply measured size/count bounds and strict JSON validation. Preserve existing
checkpoint/journal keys and schemas. Native loading must validate key/identity and
isolate corrupt session records while retaining original bytes.

Creation/update requires an exact expected revision and current bound approval;
stale/concurrent writes must fail without changing prior records. Reads/reopen
must produce no command/model request, no automatic dispatch or advancement and
no fabricated completion. A saved active dispatch is an interrupted observation
until existing reconciliation evidence is explicitly validated. Cancellation is
retained session intent, never proof that a command exited. Session membership
and progress records cannot expand existing execution or promotion authority.

Acceptance for that first increment is typed roundtrip/invalid-binding tests,
conditional create/update refusal, approval withdrawal, immutable prior values,
corrupt-record isolation and real native close/reopen with zero dispatch. It is
a data/storage prerequisite; controller scheduling, chat/session activity UI and
full CE01 remain later unmet acceptance, not capabilities delivered by this note.


### Approved session data and native storage — 18 November 2026

The first session increment is observational data/storage, with no controller,
scheduler or chat UI integration. AgentSession freezes session/project identity,
exact approved Plan, dependency-closed selected task membership, append-only
existing-run references and cancellation intent. It does not store fabricated
task completion. Task status/title are authored board data and are excluded from
this membership snapshot. Bounds are64 tasks (bounded dependency traversal),128
dispatch references,64KiB UTF8 per approval content/context and256KiB for encoded
session JSON; boundary and dense-graph/Unicode tests enforce these limits.

AgentSessionStore creates records only for mapped tasks in the current approved
Plan. Observation requires an exact saved candidate journal run, matching approval
and Plan task graph, canonical project/run dispatch and saved execution checkpoint.
The selected task is contextual correlation, not proof that a particular proposal
was consumed, a task completed or a command exited. This initial version accepts
the existing canonical candidate-run dispatch format only; it is not a generic
tool-dispatch schema. Conditional writes compare session revision plus approval,
project/context and referenced journal/checkpoint bytes; stale/concurrent changes
refuse without overwriting prior data. Existing journal/checkpoint formats remain.

Cancellation can be recorded even after approval withdrawal because it adds no
execution authority. It only retains intent and never signals a process or edits
a referenced checkpoint. Creation and new observations still require current
approval. Load/reopen is a read, including historical or revoked approval records;
it never dispatches, reconciles, advances or treats stored references as current
authority. Scheduling/recovery decisions remain unimplemented in this increment.

Records use studio.agentSession.v1.<projectId>.<sessionId>. StudioDatabase checks
bounded JSON/key identity and isolates corrupt session records; originals remain
verbatim. Real native close/reopen tests retain observations/cancellation while
an existing executing checkpoint remains byte-identical, and corrupt sibling
session records do not block valid history. No app-crash, live model, UI or broad
CE01 completion claim follows from these data/storage tests.


### Workspace saved-session management — 18 November 2026

Flutter project workspaces now expose Saved work sessions through a focused MVC
screen/controller. Users explicitly select approved mapped tasks and confirm
saving the selection; prerequisites/dependents stay closed when toggled. The
screen reopens saved history or a direct session ID and records cancellation
intent. Missing/revoked approval blocks creation while history stays available.
No command, inference, automatic resume or task completion is introduced here.
Saved run references remain contextual observations with the prior limitations.

A bounded per-project catalog uses studio.agentSessions.v1.<projectId>, with128
unique session IDs and a32KiB encoded limit. New session and catalog publication
are one conditional transaction; concurrent writers cannot leave an orphan
session or lose another catalog update. Pre-catalog records remain loadable by
ID. Explicit Add session to list registers a retained record without changing it
or requiring execution approval. Corrupt catalog data prevents discovery/new
creation, but direct ID reading and cancellation intent remain available. Native
validation isolates corrupt catalogs and preserves original bytes.

Controller APIs own validation, task selection, loading/errors and saved state;
views own navigation/form consent and text-controller lifetime. Pending writes
block duplicate actions; a failed save retains visible history and shows a
recoverable error. Disposal ignores late UI results without pretending an already
committed write was undone. Missing selected records show a retained-snapshot
warning. At128 indexed sessions, creation/registration is disabled with an
explicit limit message, while existing history remains readable. No records are
automatically deleted or hidden to make space.

Deterministic coverage includes atomic catalog races/failures, pre-catalog
registration after approval withdrawal, corrupt catalog/native reopen, controller
persistence ordering/disposal,320px2x create/cancel/reopen and visible save errors,
and the actual workspace navigation entry. Browser IAB navigation/missing-approval
evidence is recorded separately; it does not substitute for actual model or
multi-task execution acceptance. The broader CE01 scheduler/dispatch linkage and
chat-driven execution workflow remain pending under #404.
