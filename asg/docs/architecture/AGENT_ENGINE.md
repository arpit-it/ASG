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


### Selected session to verification admission investigation — 18 November 2026

Saved-session management currently carries no selected session into source review.
Its workspace route returns void; SourceGenerationController.createSourceReview
and SourceReviewController construct candidate controllers without a session
binding. SourceCandidateController.verify persists a candidate run/execution via
CandidateVerificationStore.start, then prepares receipts and enters host.verify.
AgentSessionStore.observeRun is a separate historical-observation transaction and
has no controller caller. Existing candidate journals still track every admitted
run; the missing link is to the selected session, not a missing global journal.

Sixty-three focused session-store/session-controller/candidate-controller tests
passed in /tmp/asg-404-session-binding-investigation-tests.log. They verify the
existing boundaries, not session-bound command admission. A later post-command
observeRun call cannot establish the desired atomic session admission guarantee.
A failed session write after command entry could leave that session unlinked even
though the candidate journal is intact. The link must be committed before receipt
preparation/host entry and guarded throughout the selected review's authorization.

The next coherent increment should offer an explicit Use session for source review
choice, carrying an immutable project/session/approval/task binding through the
workspace/build/review/candidate flow. Reopen must not select or dispatch it
automatically. Unbound existing review behavior remains available; an explicitly
bound review must never silently drop a stale/cancelled binding or fall back to
unbound execution. The selected board task must belong to the approved session.

Candidate startup should commit session reference, journal, candidate snapshot
and execution checkpoint together, comparing exact session and approval/context
bytes. Use a typed bounded admission interface with fixed validated keys, not an
unrestricted extra-update callback. AgentSessionStore currently imports the
candidate store, so adding the reverse dependency without extracting a shared
validator/typed admission boundary would introduce a service cycle. Existing pure
session/run models can supply validation while one transaction owns publication.

Authorization must reject changed approval/membership, cancellation, stale or
corrupt records and disposed reviews before receipt/host entry and before later
operations. Cancellation remains intent; the already-running command may have
an unknown exit and its actual evidence must be retained through existing Stop
and recovery paths. Session checks must not replace Plan approval or confinement.
Promotion must also compare the bound session in its atomic expected inputs;
cancellation during preview startup must retain old working output. A cancellation
after a committed publication cannot undo it or justify automatic rollback.

Acceptance for that increment: explicit context selection and propagation;
atomic startup failure leaves every record unchanged and host/preparation counts
zero; concurrent cancellation/stale session refuses admission; later cancellation
retains actual exits/unknowns; promotion races preserve the correct publication
boundary; native reopen keeps exact session/run linkage without replay. Cover
legacy unbound behavior, disposal and no changed working pointer on refusal.
This remains a bounded existing-verification integration, not a scheduler,
arbitrary tool framework, automatic task completion or full CE01 acceptance.


18 November 2026 — selected-session verification admission implementation

The workspace now offers an explicit Use session for source review action and a
clear-context control. Reopening a session never selects it automatically or
starts work. Build and review display the chosen session. Current project/Plan,
frozen membership and exact session snapshot are checked before source capture,
model requests, candidate copying and candidate effects; invalid selected context
cannot silently become unbound. Review retains the successfully admitted snapshot
for explicit retry/repair, while a newly opened Build needs a fresh selection if
its workspace snapshot is stale. Existing unbound reviews keep their behavior.

AgentSessionRunAdmission validates a typed binding and produces a private-created
fixed-key reservation. CandidateVerificationStore.start alone consumes it in the
same conditional transaction as journal, candidate and canonical execution
checkpoint. Exact session and fixed approval/context bytes are expected inputs;
the session append commits before receipt preparation or host verification.
No arbitrary update callback or reverse candidate/session-store import is added.
The controller adopts the appended snapshot only after that commit. Session
validation supplements existing consent, confinement, Plan and working guards.

Promotion validates the selected session's immutable basis and latest verified
run reference, then includes exact current session bytes in its existing expected
inputs. A cancellation before commit refuses publication and retains the previous
working output; publication already committed is not rolled back. Session
cancellation remains intent. Actual running-command observations and unknown exits
continue through the existing journal/Stop/recovery paths without fabricating
completion. Native close/reopen tests retain the joint admission without replay.
This is existing verification integration, not automatic scheduling, arbitrary
source synthesis, new model permissions, task completion or full CE01 acceptance.


18 November2026 — native selected-session admission investigation started

Protocol10's makeController in tools/fixtures/native_candidate_crash.dart passes
no sessionBinding; its promotion SourceGenerationController passes no selectedSession.
The host's bounded nonce/dispatch report validation checks existing Stop/recovery,
retry and promotion evidence but contains no session identity/revision/reference
assertions. Existing PR726 native database close/reopen proves atomic retention
in one test process, not an actual killed fixture and separately launched reopen.
Fourteen deterministic native crash-host tests and24 binding/admission/journal
tests pass on merged9042809df781d32970a53ccbb1f65d731bbed52d
(/tmp/asg-404-session-native-admission-host-tests.log and
/tmp/asg-404-session-native-admission-tests.log). No process kill or live inference
was run during this investigation; old unbound binaries remain historical evidence.

The smallest next acceptance is an explicit opt-in bound-session mode in the
existing isolated fixture, initially restricted to the approved mapped Stop/test
path. Create the session only after the fixture Plan is approved, pass one typed
binding using the exact controller storage wrapper, and pass its immutable basis
to promotion. Reports should include bounded session identity/revision and hashes
of retained session/journal/execution plus exact reference membership; fail closed
for absent/mismatched/rewritten records, wrong mode/version/nonce, or automatic new
run on reopen. Test a startup refusal/crash boundary before receipt/host entry and
a post-admission process kill with separately launched read-only reopen, preserving
real observed exits/unknowns and existing prior output. Keep protocol10 observations
identified as unbound; a new protocol/mode must not relabel them. Broader bound retry,
promotion/cancellation process cases follow only after this minimal boundary is
verified. No scheduler, synthetic completion or stable bundle replacement is needed.


18 November2026 — native session admission fixture implementation

Protocol11 adds explicit --session-bound for the mapped --operation test --stop
path only; --admission-crash requires that mode. Running/uncertain/acknowledgment,
retry/promotion and the older Stop precommit flag are refused in bound mode before
launch. Existing unbound modes remain explicit sessionBound=false with no proof.
Protocol10 observations retain their historical identity and are refused by the
new host; they are not renamed or reused as session-bound acceptance.

The fixture creates an approved full task session after its Plan approval, uses
the identical controller storage wrapper for typed admission, and checks the fixed
session/project/board task/reference and exact session/journal/candidate/execution
hashes. The host validates bounded proof schema, strict integer revisions/counts,
mode/version/nonce, pre-admission absence and zero effects, and compares retained
identity/hashes between separately launched apps. Reopen reports zero new receipt
preparation/command entries; neither opening a view nor reading evidence dispatches.
The top-level planned dispatch token in the pre-admission handshake is not a saved
dispatch: its session proof has null dispatchId and zero references/startup records.

An isolated fixture-only storage barrier pauses the combined admission transaction
before delegating any write. At that boundary session revision0 is unchanged, the
journal/candidate/execution are absent, no receipts/command marker exists and prior
working/source hashes match after the owned app is killed and separately reopened.
The post-admission case uses the production candidate controller and native host,
observes actual resolve/analyze/test receipts, pauses before the last command result
reaches its journal checkpoint, records Stop intent, kills only the owned app and
reopens read-only. Revision1, its one exact reference and all four record hashes
remain identical. The retained actual test receipt exit0 does not mark the pending
journal operation or task complete. Prior working output remains unchanged.

The two new observations use binary
e7322d48e14b7e31bb67459d1d8435dd31388034f288f619e8ebcd926a734c1a
and /tmp/asg-404-native-session-admission-{precommit,committed}-observation.json.
This is bounded fixture evidence, not production-main navigation, arbitrary source
synthesis, generalized scheduling, live inference, another platform, or bound
session retry/promotion/cancellation-process acceptance. Existing deterministic
controller tests cover narrower session cancellation and promotion races.


18 November2026 — native first-receipt session cancellation fixture

Protocol12 adds --session-cancel only with --session-bound --operation test --stop;
other running/uncertain/acknowledgment/retry/promotion/admission-crash combinations
are refused before launch. Here --stop selects the approved mapped fixture slice;
this mode does not request a Candidate Stop signal. Its report explicitly requires
candidateStopPresent=false, and no running-process cleanup or exit is inferred.
Protocol10/11 observations keep their original identities and cannot be relabelled.

After the actual native resolve command returns its validated receipt, the fixture
saves the exact uncancelled admitted binding and calls production session
requestCancellation. The stored session becomes revision2 with its existing one
reference and cancellation intent. Production candidate progress retains the real
resolve exit0 before rechecking session authority; the next command is refused.
The attempt closes with candidate phase failed, no pending command, and execution
phase verifying. Neither a closed attempt nor that checkpoint phase means the full
check graph or board task completed. Promotion remains unavailable.

Before the owned app is killed, the fixture validates exactly one resolve step and
receipt, no analyze/test/build command markers, unchanged candidate source and
seeded prior working files/record, and hashes the receipt context, intent and raw
result bytes. A separately launched app reopens read-only with the saved pre-cancel
binding, checking that its cancellation successor exactly equals the actual stored
record. It never silently falls back to an unbound controller. Session/journal/
candidate/execution/receipt hashes and cancellation intent remain identical, with
zero new preparation or command entry. Report validators reject wrong mode,
missing/rewritten evidence, fabricated exit, later work and promotion permission.

Final actual cancellation evidence is
/tmp/asg-404-native-session-cancellation-final-observation.json on binary
8356dfccefbfd21aa02b408ea83d7a3c1b82ddf895469dec0c4afbf2b637b44d.
The same binary passed both session admission modes and four legacy scenarios,
including the five-launch running Stop/acknowledgment/retry/promotion-commit crash.
The earlier 98ba809b0117d67aac3dd7903085ee7623c1d58db9dd5d7e25d91fd89b4461e2
observation preceded the tightened binding ancestry check and is not final-source
acceptance. This remains bounded fixture evidence: no production-main navigation,
live inference, running-command session-cancellation cleanup claim, bound retry/
promotion-process proof or full CE01 acceptance is added.


18 November2026 — native same-session explicit retry fixture

Protocol13 admits one additional bound slice: --session-bound --operation test
--stop --running --acknowledge --retry, with promotion, uncertain, precommit,
admission-crash and session-cancel refused. This is an uncancelled session;
Candidate Stop intent and actual stopped test exit do not cancel the session.
Partial/conflicting flag combinations refuse before any app launch. Historical
protocol10/11/12 observations retain their original identities.

The existing four-launch flow first stops the actual running test, then reopens
read-only before explicit receipt-backed acknowledgment, then reopens with fresh
unchecked consent before invoking the real verification checkbox/button callbacks.
Only that explicit consent permits the second canonical dispatch and actual
resolve/analyze/test/build commands. The fourth app reopens without preparing or
entering any command. Session revisions/counts are 1/1/2/2 and command entries
are 3/0/4/0. Both ordered dispatch references retain the same frozen approval/task
basis; a cancelled session is not revived or silently made unbound.

A separate bounded sessionRetryProof tracks immutable basis, session bytes,
ordered IDs, journal/candidate, first run/checkpoint/receipts/Stop/recovery audit,
and second checkpoint/receipts. Receipt hashes include validated context/intent/
result bytes and require the complete expected result set: first resolve/analyze
exit0 and stopped test exit-1, then four uncancelled retry exits0. Generic receipt
and first-dispatch session proofs cannot stand in for this stage-specific proof.
One canonical before-action digest excludes only local effect counters. The host
compares it to the preceding after-action proof. Acknowledgment must change the
first run/journal/checkpoint while preserving the session and actual receipts;
retry must append the second reference while retaining immutable first-run audit;
the last read-only reopen must preserve all record hashes. This avoids claiming
that an authorized acknowledgment or retry left its journal unchanged.

Final same-session retry evidence is
/tmp/asg-404-native-session-retry-reviewed-observation.json on binary
76112128c6526a5495409d6068109360650a5ffa0ecd5549cc537fd0e8846d7a.
The earlier213fa7f4392b65342a81be62deb694f3ad2b013662792e26ecb6a16b57441ed6
observation preceded the receipt-completeness guard and is not final-source
acceptance. This remains fixed fixture evidence, not production-main navigation,
automatic scheduling/replay, arbitrary model source synthesis, live inference,
cleanup confirmation or full CE01. Bound native promotion remains pending.


PR730 fresh review found that the first host implementation validated cross-stage
proof only after all launches. The reviewed fix validates each report against the
preceding stage before crashing/waiting for that app or starting another app.
A deterministic corrupted-acknowledgment regression confirms that only the first
two app handles are created; no retry app launches. All eight actual scenarios
were rerun with the revised host on the unchanged fixture binary. The reviewed
observation files use /tmp/asg-404-native-session-retry-reviewed*-observation.json;
the earlier final-named files do not establish the revised guard-order behavior.


18 November2026 — native bound-session publication and committed crash recovery

Protocol14 extends the full bound Stop/acknowledgment/fresh-consent retry path
with explicit promotion, optionally crashing after the atomic database commit
but before the production controller reports success. Partial/conflicting modes
refuse before launch. Historical protocol13 evidence keeps its original identity.

The fixture retains the original approved revision0 selection in a bounded,
canonical private control file, validates its identity/approval/frozen membership
on every reopen, and passes that basis to the real publication controller.
Verification uses the current admitted binding. Missing basis refuses; production
selection ancestry and cancellation guards are unchanged. This mirrors a retained
selection across explicit dispatches, rather than substituting the latest binding
for the selection basis or granting new authority.

Promotion-stage proof adds working/previous pointer hashes, exact second-run
publication identity and execution phase to the retained session/journal/receipt/
Stop/recovery proof. Injected precommit refusal must preserve the complete proof.
Successful promotion changes only working/previous and second execution state;
the journal, candidate, first audit, both receipt sets and session remain exact.
The previous pointer equals the prior working pointer. The prepared actual native
preview responds HTTP200 with HTML, including at the committed crash barrier
where controller success has not been delivered. Fifth-launch read-only reopen
retains exact committed records and enters zero SDK commands or preparations;
it does not start or claim a surviving preview process. All stage transitions
validate before a subsequent app launch.

Native bound-session promotion final local evidence: protocol14 normal and postcommit-crash five-launch scenarios passed, plus eight prior retry/cancellation/admission/legacy regressions on one binary f4ce541fef4003deaddc35057a38a6ede6b84d13b59a29333563c9787479fcbd. Each new flow retains the initial session-selection basis separately from the current binding; precommit refusal preserves all stage records, actual production promotion serves HTTP200 and commits working/previous pointers with the second completed execution checkpoint. Commit-gap observation occurs before controller success, and the fifth separately launched read-only app preserves exact committed state without new dispatch or rollback. Evidence: /tmp/asg-404-native-session-promotion-{normal,commit-crash,retry,cancellation,admission-precommit,admission-committed,legacy-resolve,legacy-stop,legacy-precommit,legacy-promotion-crash}-observation.json. Host38/probe6/product32/inventory9, fullFlutter1,908/11skip, analyze, explicit fixture Dart analysis and isolated native build passed. Per-stage guards run before subsequent launches. Only owned fixture handles killed; no product guard changes, live inference, stable app replacement, full task completion or cleanup claim. Exact PR review/required CI/verified merge remain gates; full CE01/#404 remains open.

This is bounded real-SDK native fixture evidence, not production-main navigation,
browser-rendered visual acceptance, live model synthesis, general task-graph
completion or universal process cleanup. The seeded prior working snapshot is
a retained output baseline, not evidence of a previously running live app.


18 November2026 — saved-session recorded run overview

AgentSessionRunStatusStore joins ordered references to the saved journal and
checkpoint using load only. It never calls execution reopen, which would mutate
executing to recovering. It verifies the saved selection is still exact, then
correlates canonical project/run/dispatch identity, approved wire graph and selected
board-task IDs. The saved Plan graph is compared without consulting today's board
or reauthorizing the old Plan; revoked/cancelled history stays readable. The full
historical board is not retained, so this does not independently reconstruct its
requirement/dependency metadata or prove original dispatch admission.

Typed status data reaches AgentSessionController through an injectable service.
Opening/reloading a selection refreshes rows without writes; unavailable evidence
has no usable phase. A bad checkpoint affects its own row; a malformed journal
makes its referenced rows unavailable while preserving all raw bytes. The screen
shows recorded candidate/checkpoint phases and explicit unresolved operations.
These facts are never aggregated into task/session completion or actual external
exit, live preview or process cleanup. No new actions or authority are introduced.

Saved-session overview implemented locally: typed read-only status projection, injectable service, selected-session controller refresh and per-run screen rows. Exact persisted session/run/dispatch/checkpoint identities, approval snapshot, approved wire graph and selected board-task IDs are correlated; stale/missing/corrupt records yield unavailable without writes. Ordered references preserve valid rows when another checkpoint is missing. Pending operations remain unresolved, checkpoint phase is a recorded fact rather than external exit/task completion. Full historical requirements-board contents are not retained, so this is correlation to the saved selection and approved graph, not independent reconstruction of historical board requirement/dependency metadata or proof of original admission/proposal consumption.

Validation: focused22 before the final two graph/order tests; final fullFlutter1,917 passed/11 existing skips, analyze clean and web build passed. New tests cover read-only byte retention, revoked/cancelled history, corrupt/foreign/missing/replayed checkpoint, journal/approval/graph mismatch, ordered partial availability, controller reload/selection/disposal and 320px text-scale2 rendering. Existing baseline25 passed. Evidence /tmp/asg-404-session-run-overview-{focused,final-tests,final-analyze,web}.log. IAB createBrowserTab(http://127.0.0.1:9127) timed out waiting for webview attachment; inventory then showed no IAB tabs. CUA outcome recorded, no Chrome fallback or hidden browser data seeding. Browser acceptance remains pending; publish only draft, no merge/full CE01 claim until acceptance and exact final review/required CI pass. Temporary preview belongs to this task; owner app/model processes untouched. No live inference required or claimed.


### CE01 active-command session cancellation investigation — 19 November 2026

The existing native cancellation observation is after-exit evidence: the
sessionCancel branch waits for resolve exit0 and its actual receipt before
requesting cancellation. It cannot establish withdrawal during a command.
The running-test branch is a different mechanism: after its nonce marker it
calls SourceCandidateController.cancel(), signalling Candidate Stop/host
cancellation. Combining those results would falsely turn session intent into
process termination evidence.

Production ordering is suitable for a narrower native proof without product
changes. Candidate startup atomically appends session admission and execution
identity. NativeGenerationHost.verify writes a pending-operation checkpoint
through beforeStart before Process.start. generation_command.py creates the
exclusive operation intent receipt before confined execution and publishes the
actual result after it. SourceCandidateController._progress retains real
observations after withdrawal, but requires current session authority for the
next pending dispatch. AgentSessionStore.requestCancellation persists intent;
it does not call the host cancellation flag or fabricate an exit.

Next bounded fixture outcome, under #404 after this investigation merges:

1. Admit one approved bound session and actual resolve/analyze/test sequence.
   Fixed test source writes a nonce running marker and waits for a bounded,
   nonce-scoped release file established at fixture construction time. This is
   a disposable test barrier, not a source edit during execution.
2. At the marker require the matching test intent and absence of test result;
   retain journal pendingOperation=test, executing checkpoint, one session ref
   and current/previous working hashes. A missing/late/malformed marker fails
   closed before cancellation or release.
3. Request only AgentSessionStore cancellation against the admitted snapshot.
   Require revision2/cancellationRequested=true, immutable approval/task/ref,
   no Candidate Stop record and no host cancel signal. Do not call candidate
   cancel, report actual termination, or acquire any additional permissions.
4. Release the fixed test and await its actual exit/validated result receipt.
   Require three command entries (resolve/analyze/test), no Build entry, real
   test exit0 without cancelled=true, retained actual receipts/first reference,
   failed candidate after authority refusal, finished journal and verifying
   execution checkpoint. These terminal observations do not complete the Plan.
5. Kill only the owned app handle after those observations. A separately
   launched read-only app must retain exact session/cancellation/journal/
   checkpoint/receipts/source/working hashes, enter zero SDK commands or receipt
   preparations, refuse promotion/consent revival and perform no retry.

Use a new explicit host/fixture mode and protocol version, rejecting partial or
conflicting Stop/acknowledgment/retry/promotion/admission options before probing
or launching. Keep old after-resolve cancellation and running Candidate Stop
observations labelled with their original identities. Validate each report and
stage before later launches. Compare the actual complete receipt set and raw
record hashes, not journal labels alone. Natural late exit is the bounded new
native acceptance; crash while the command itself is still alive and general
cleanup/reconciliation remain pending unless separately established.

Evidence inspected: generation_host_native.dart verify/beforeStart/dispatch;
generation_command.py CompletionReceipt and confined execution; candidate
controller _authorize/_progress/verify; native fixture running handshake,
nonce test source, sessionCancel after-resolve branch and host cancel flag.
Existing focused source-candidate/session-store baseline61 passed; current
specific unknown-running-outcome controller regression1 and completion-receipt
fixtures3 passed. Logs are /tmp/asg-404-session-cancellation-running-investigation-
{baseline,unknown,receipts}.log. No new native observation, inference, device
support, cleanup or fullCE01 acceptance is claimed by this investigation.


### CE01 native active-test session withdrawal — 19 November 2026

Protocol15 adds --session-cancel-active only with the complete existing
--operation test --stop --session-bound --session-cancel slice. It must not use
--running, which still denotes the separate Candidate Stop fixture, or any
acknowledgment/retry/promotion/pre-admission fault mode. The fixed harness's
--stop switch selects the mapped approved fixture setup; actual Stop evidence
remains candidateStopPresent=false and stopSignalled=false in this cancellation
slice. Old protocol14 observations keep their original identities.

The fixed native test writes a nonce marker, then waits at a bounded nonce
release-file barrier. The fixture verifies matching test intent/context and no
test result before calling production requestCancellation on the admitted
revision1 snapshot. It requires revision2 cancellation with one unchanged
reference and unchanged pending-test journal/executing checkpoint, still no
result, no Stop record and no host cancellation signal. The fixture records
before/after session fingerprints and the actual intent/context/marker ancestry
in a bounded canonical private boundary file before releasing the test.

After release it awaits real test exit0 without cancelled=true. Production
observation persistence retains resolve/analyze/test results after withdrawal;
the next authority check refuses Build. The resulting failed candidate/finished
journal/verifying checkpoint is a saved refusal after three real results, not
Plan completion. A session proof fingerprints the full three-receipt set and
active boundary. Reading that boundary revalidates exact intent/context/marker,
admitted basis and cancelled-session bytes rather than trusting a phase label.

The host kills only its owned app handle after terminal observations. The second
separately launched app reopens cancelled history read-only; raw durable and
receipt fingerprints must match, source/working state stays unchanged, and
preparations/command entries are zero. The host refuses malformed/missing active
boundary, wrong receipt prefix, nonzero or bool test exits, host Stop signals and
partial/conflicting modes before launch. The old after-resolve cancellation
mode cannot be relabelled using the running Candidate Stop flag.

This proves natural late completion after persisted session withdrawal. It does
not establish process termination on session cancellation, crash while the test
itself remains alive, general cleanup, automatic reconciliation/retry, arbitrary
model synthesis or full CE01. No production permissions or runtime code change.

Native active-session withdrawal final local validation: protocol15 --session-cancel-active new two-launch scenario and ten earlier normal/commit-crash/retry/after-exit-cancellation/admission-precommit/admission-committed/legacy-resolve/legacy-stop/legacy-precommit/legacy-promotion-crash scenarios all passed on binaryafac45ce843d198bb7b5ed00e77af298a4e9712cf937032e491f5a1d47fd0e52. New proof records rev2 cancellation before test result, validates unchanged pre-exit intent/context/marker/admitted-basis ancestry, preserves actual exit0 and complete resolve/analyze/test receipts, refuses Build/promotion and retains failed candidate/finished journal/verifying checkpoint. Owned-app crash then separate read-only reopen preserves exact durable/receipt/source/working evidence with preparations1/0 and commands3/0; no Candidate Stop or host cancellation signal. Evidence /tmp/asg-404-native-session-cancellation-running-{active,normal,commit-crash,retry,cancellation,admission-precommit,admission-committed,legacy-resolve,legacy-stop,legacy-precommit,legacy-promotion-crash}-observation.json. Host41/probe6/product32/inventory9, fullFlutter1,918/11skip/analyze, final fixture Dart analysis and rebuilt isolated native bundle passed. No new live inference, stable app replacement, process-termination/general cleanup or fullCE01 claim. Fresh exact PR review/required CI/verified merge remain gates.

PR734 reviewed correction final local evidence: fully flushed release permit now publishes by same-directory atomic rename, preventing the active test from seeing an empty file. Rebuilt binaryf1b88525686ccc078a7f93427e62f25f938311b9b9e027712698e3f2bc4f7d34 passed12 native observations: reviewed-{active,active-repeat,normal-retry,commit-crash,retry,cancellation,admission-precommit,admission-committed,legacy-resolve,legacy-stop,legacy-precommit,legacy-promotion-crash}-observation.json under /tmp/asg-404-native-session-cancellation-running-. Original reviewed-normal attempt remains refused/uncertain and preserved (control asg-candidate-crash-0pt7uhpp; later validated cancelled receipt, cleanup unknown); it is not counted as acceptance or a zero-flake claim. Initial afac45ce observations are historical and superseded for revised source. Final fixture Dart analysis/rebuilt isolated native bundle and host41/probe6/product32/inventory9 pass; core lib/test inputs unchanged from1918/11skip/analyze run. Required new-head CI must rerun all mandated checks. One blocking fresh-review release-publication race fixed; fresh revised review/CI/verified merge still required.


### CE01 cancelled active test with unpublished result — 19 November 2026

Protocol16 adds --session-cancel-unknown only with the complete
--operation test --stop --session-bound --session-cancel --session-cancel-active
mode. All prior report versions retain their historical identities and are
refused by the current observer. The new mode cannot combine with Candidate
Stop, acknowledgment, retry, promotion or pre-admission faults.

After the existing actual test marker/intent and revision2 session withdrawal
boundary, the fixed private helper exits before publishing test.result.json.
The nonce fault marker proves this injected publication boundary only; helper
exit73 is not a validated Flutter exit, command cleanup or termination proof.
The candidate retains actual resolve/analyze exit0 receipts and the incomplete
test intent. It remains failed and unfinished with pendingOperation=test and an
executing checkpoint. Both retainedExit and actualTestExit are explicitly null,
cleanup is unknown, and no acknowledgment, Candidate Stop, host cancellation
signal, Build or promotion is present.

The fixture fingerprints the actual receipt prefix plus raw incomplete intent,
requires the test result path to be absent (including no dangling link), and
retains the nonce fault fingerprint independently. After the observer kills only
its owned app, a separately launched read-only reopen must retain identical
session/journal/candidate/checkpoint/receipt/source/working evidence. Its receipt
preparations and command entries must both remain zero. The first launch has one
receipt preparation and three command entries; command entry is not a completed
result. This bounded fault proves refusal to invent a test outcome, not general
process cleanup, automatic recovery or full CE01 acceptance.

CE01 unknown-result cancellation final local validation: protocol16 binarye5e71ec300c02b77b17d6155e6e051849f99299d40083d04371f4f11cb2db92a passed13 isolated native observations (two unknown-result plus11 relevant prior modes). Raw incomplete intent, actual resolve/analyze results, revision2 cancellation/one reference and failed unfinished pending-test/executing state survived separate read-only reopen, counters1/0 preparations and3/0 commands, null test exit/cleanup unknown. Host44/probe6/product32/inventory9, explicit fixture Dart analysis, isolated macOS build, final Flutter analyze and full1,918 passed/11 existing skips. Evidence /tmp/asg-404-native-session-cancellation-unknown-{first,repeat,active,normal,commit-crash,retry,cancellation,admission-precommit,admission-committed,legacy-resolve,legacy-stop,legacy-precommit,legacy-promotion-crash}-observation.json and final-{analyze,tests}.log. No new live inference, stable app replacement, generalized cleanup or fullCE01 claim. Fresh exact PR review/required CI/verified merge remain gates.


### CE01 per-task transition investigation — 19 November 2026

Inspected source at verified main d41efada (PR735). This is an investigation,
not implementation or acceptance of a persistent autonomous loop.

| Existing record or boundary | What it establishes | What it cannot establish |
| --- | --- | --- |
| AgentSessionTask / AgentSessionTasks | Frozen dependency-closed task membership and requirement IDs | Authored board status, runtime progress or completion |
| AgentSessionDispatch / AgentSession.observe | Append-only candidate run reference in one selected task context | Tool entry, successful result, task completion or dependency readiness |
| AgentSessionRunAdmission.prepare | Current approval and membership checked; session reference joins candidate startup transaction | Execution of a single board task; the candidate still verifies the whole fixed Plan |
| CandidateVerificationStore.start / checkpoint / _commit | Atomic candidate/journal/execution startup and later snapshots | A per-task transition timeline; session reference currently changes only at admission |
| AgentSessionStore.requestCancellation | Durable session withdrawal, one revision increment, retained history | Child process termination, command exit or cleanup |
| AgentSessionRunStatusStore | Read-only correlation of saved run/checkpoint facts, including unknown pending operations | Original admission proof or new execution authority |
| AgentSessionController.selectForSourceReview | Uses the first selected task to validate navigation, then returns the whole selected session | Selection of the actual proposal task or task scheduling |
| SourceReviewController source review | Binds the proposal evidence boardTaskId to session membership; candidate authorization compares that ID again | Completion of that task or scheduling a dependent task |

Concrete missing datum: there is no typed per-task sequence explaining admitted
verification, pending operation, actual observed operation result, interrupted
unknown outcome and finished verification. The existing version1 session has
eight exact fields; its revision is admissions plus optional cancellation. Adding
transition fields there silently would break its validation and reinterpret
historical references. Board task status/title edits must remain separate from
execution evidence. A successful fixed whole-Plan check or working promotion is
not sufficient evidence that a particular requirement task is complete.

The next bounded prerequisite is a pure typed transition model, before storage
integration. It describes observations in a selected task context, not arbitrary
instructions. Keep the existing AgentSession schema unchanged. The model must:

- Bind one immutable project/session/task and one candidate run/dispatch identity
  to a versioned, bounded, immutable sequence. Resolve membership from a supplied
  frozen session snapshot; reject another session, task, run or malformed ID.
- Admit only fixed observation kinds: verification admitted, operation pending,
  operation result observed, verification interrupted with unknown outcome, and
  verification finished. Session cancellation is an independently supplied
  withdrawal fact, never an observed command result or a fabricated exit.
- Validate fixed resolve/analyze/test/build ordering. Pending comes before its
  matching result; actual result retains exit and cancellation facts separately.
  An incomplete intent cannot become exit0, exit73 or cancelled=true merely
  because a helper failed. No free-form operation or executable content.
- Require an admitted prefix, contiguous sequence numbers and bounded operation
  data; reject duplicate, missing, reordered or contradictory observations.
  Interruption retains the pending operation and actual earlier results.
  A finished verification has no unknown pending operation. Failure may finish
  with observed results; finished does not mean ready or task completed.
- Permit a genuinely observed pending-command result after session withdrawal,
  while refusing any new pending operation under withdrawal. The caller must
  validate receipt provenance; this pure model cannot authenticate supplied facts.
- Remain inert: no clock, file/network/process/plugin/storage access, scheduling,
  task completion, dependency unlocking, approval renewal or replay. Serialization
  is deterministic; invalid input leaves existing values unchanged.

Acceptance examples for that prerequisite are recorded only in REQUIREMENTS.md.
The model can be tested on this Mac with deterministic inputs and architecture
checks. Native atomic persistence and UI integration remain unmet boundaries;
this investigation does not claim either, nor declare a new independent queue.
Existing session receipts and native observations keep their original source,
model, protocol and host identities. No live inference is needed for this work.

Storage integration must later preserve the existing candidate startup CAS and
observation-after-withdrawal ordering. It must not perform an independent history
write that succeeds while candidate startup fails, or require fresh execution
authority merely to retain an actual result. This is a constraint on integration,
not permission to implement or execute it here. Process reconciliation remains
operator-confirmed; a saved PID or event never authorizes termination.


### CE01 typed task verification observations — 19 November 2026

AgentTaskHistory is a pure validation prerequisite in models/agent_task_history.dart.
It performs no record writes, command dispatch, receipt authentication, process
reconciliation, task completion or dependency unlocking. Existing AgentSession
version1 bytes and candidate workflows are unchanged.

Version1 history has exactly version, session, reference, withdrawalSequence and
observations. Its basis is a frozen uncancelled AgentSession containing the exact
last admitted reference. The task, run, dispatch, approval and selected dependency
graph therefore stay bound together. A supplied currentSession must equal that
basis or its single cancellation successor, not a later admission or replacement
approval. Historical callers must retain the original admitted snapshot; this is
not a projection against an arbitrarily newer session. No constructor proves
that its caller's claimed admission or result actually occurred.

Each observation has exactly sequence, kind, operation, exitCode and cancelled.
Kinds are admitted, pending, result, interrupted and finished. Operations reuse
BuildOperation's resolve/analyze/test/build allowlist. Only result has integer
exitCode and boolean cancelled; all other kinds require both fields null.
Sequence0 is admitted; subsequent positions must be contiguous. Results require
matching pending operations in fixed order. A failed/cancelled result cannot
start another operation. Interruption retains the pending operation; an actual
late matching result can be recorded, but the interrupted attempt cannot start
further work. Finished requires no unknown pending operation and is terminal;
it says only that this verification attempt ended, never that a task succeeded.
A pre-command failure may finish with an empty actual-result prefix.

Withdrawal is a separate caller-observed boundary, the next observation index
when cancellation was supplied. It never supplies an operation result. Append
requires a current snapshot; withdrawal can only be added or retained. A pending
operation at/after withdrawal is refused, while the existing pending operation's
actual result remains recordable. Reading older history with a now-cancelled
matching session does not rewrite its boundary; a later append/explicit withdrawal
observation must retain cancellation and cannot dispatch anything. Clearing a
recorded boundary with an uncancelled snapshot is refused. The model cannot
verify when a caller-supplied boundary or result occurred; storage integration
must validate provenance and atomically retain it with the candidate journal.

The record permits at most16 observations and AgentSession.maxEncodedBytes+8192
UTF-8 bytes, with strict version/types/keys and signed32-bit exit integers.
Collections and snapshots are immutable; serialization returns detached values.
Unknown helper failure remains null, not exit73, zero or cancelled=true.
Native persistence, controller/UI integration, original receipt provenance and
full CE01 acceptance remain pending. No new runtime/model/browser observation is
claimed by these deterministic values and tests.


### CE01 atomic bound task-history persistence — 19 November 2026

New bound candidate runs persist studio.agentTaskHistory.v1.<project>.<run> in
the same CandidateVerificationStore transaction as session admission, candidate,
journal and execution startup. Expected history absence prevents an orphan or
foreign record from being overwritten. No receipt preparation or host entry can
precede this transaction. AgentTaskHistoryStore has no independent write method;
it constructs validated transaction inputs and performs read-only loads.

Subsequent checkpoints compare the exact prior history bytes, journal/candidate
bytes and actual saved session bytes. Immutable source/configuration/approval/
graph and the completed step prefix cannot change. A result must match an already
persisted pending intent; result and a new pending operation cannot be combined
into one observation-authorized checkpoint. Pending work and result saves retain
the existing controller authority split. Cancellation races refuse the pending
CAS before host entry; actual late results can still be saved against the
cancelled successor without new execution authority. Failed writes advance no
in-memory history/session checkpoint, so a bounded retry records no duplicate.

A failed snapshot with a pending operation records interrupted/unknown rather
than inventing an exit. Finished verification requires no unknown pending result.
Explicit recovery acknowledgment remains separate: it can close the journal's
operator-confirmed workflow while the immutable history still records an unknown
operation. A later consented run has another record and reference; it does not
rewrite the interrupted history. Candidate Stop intent remains its own existing
record and does not fabricate a task result.

Approved starter graphs may run test before analyze. New persisted history uses
model version2 with an immutable operationOrder, validated against the frozen
approved wire graph and candidate task order. Only resolve first, build last and
one of each allowlisted operation are permitted; existing version1 histories
still decode in canonical resolve/analyze/test/build order. The existing session
version1 schema is unchanged. Legacy/unbound runs without histories return null;
loads never synthesize, migrate, reconcile or dispatch. Historical reads allow
later session reference extensions only when the original approval, task graph
and entire admitted prefix remain equal. Invalid records remain retained and
unavailable, with sanitized errors.

StudioDatabase validates the new prefix, bounded size and exact project/run key
before publication and when reopening records. Deterministic CAS fixtures cover
failure, stale/corrupt history, foreign identity, source/prefix changes and
withdrawal races. Actual native database close/reopen fixtures retain exact
history/session/journal/candidate/execution bytes for startup, unknown interrupted
and known supplied late-result states. Their result values are fixtures, not
new Flutter execution, application-crash, cleanup or inference evidence.
Controller fixtures emit intent before result like the native runner and verify
no later command on withdrawal or disposal. Prior dated native binaries and
receipts retain their original revision/protocol identities.

No task completion, scheduler, automatic process reconciliation, receipt-publisher
authentication, user-interface history display or full CE01 acceptance is claimed.


### CE01 read-only saved task observations — 19 November 2026

AgentSessionRunStatusStore now includes validated task history only after its
independent run/checkpoint checks pass. History must match the selected session,
project, reference and frozen task selection. Missing, corrupt, legacy or foreign
history leaves the base run facts available with null task details; no recovery,
reconciliation, approval renewal or write is attempted. History errors do not
expose retained bytes. AgentSessionController keeps its existing read-only
load/open/selection/disposal behavior; the status model carries immutable data.

AgentTaskHistoryView renders an expandable ordered event list, human-readable
operation labels, retained actual exit fields, interrupted unknown outcomes and
the independently recorded session withdrawal boundary. A remaining pending
operation says that no result is saved. Verification-attempt finished is never
labelled task completion. Source/approval contents and command output are not
rendered. The existing saved-run facts remain visible when details are unavailable.
The focused view owns rendering only and performs no storage or application action.

Tests cover foreign/corrupt/missing histories, revoked/cancelled contexts, controller
selection/refresh/disposal, ordered unknown and late-result rows, private output
omission, zero writes, and320px layout with text scale2. Full Flutter1,952 passed
with11 existing skips; analyze, production web build, explicit fixture analysis,
fixture web build and product32/inventory9 passed.

The IAB check used tools/fixtures/agent_session_task_history.dart, a labelled
in-memory fixture using the production screen/controller/projection. Setup uses
typed stores and supplied deterministic result values; it creates no host/model
or process. After setup, writes are refused and counted. Opening/expanding unknown
and late-result sessions, opening legacy history, reloading, attempting a missing
ID and returning showed write attempts0 and unchanged records. Unknown history
retained resolve exit0 and a separate interrupted test; late-result history showed
its saved test exit0 and verification-finished row; legacy details were explicitly
unavailable while its saved run facts stayed visible. Cancellation controls were
disabled for the cancelled fixture sessions. Screenshots were visually inspected
in IAB; narrow/high-text evidence is from widget tests, not a browser viewport claim.

Evidence /tmp/asg-404-session-task-history-overview-iab-observation.json; fixture
main.dart.js67d9f56dfd0e862e8a9cd058ed985aea23f2aab46d2d75aea5f11f787910b24f,
production buildd4b8d84bf42b0bc8fcc779f37d7a22e4998520f2f3ca6c4d061f365faa9ee018.
This is read-only fixture UI acceptance, not production end-to-end coding, actual
Flutter execution, app-crash recovery, process cleanup, inference or full CE01.
Historical native binaries/observations remain tied to their original identities.


### Native saved task-history proof — 19 November 2026

Disposable crash fixture protocol17 adds taskHistory to the single-dispatch
session proof. Before accepting a report and before the next native launch, the
host requires bounded exact event rows, typed actual exits/cancellation values,
withdrawal boundary, unknown pending operation and verification-finished state.
The fixture loads history through AgentTaskHistoryStore and the same
AgentSessionRunStatusStore used by saved-session views. Both serialized typed
histories must equal the retained raw record and selected dispatch, with equal
SHA-256 fingerprints before the owned app crash and after a separately launched
read-only reopen. Pre-admission proof instead requires absent history and no
projected runs. Missing/foreign/altered history or projection refuses evidence;
no loader reconciles, dispatches or writes records.

The fixed cases distinguish actual late test exit0 after session withdrawal
from a publication fault retaining test intent/interrupted/unknown without a
result. Helper exit73 and a private fault marker remain distinct from actual
Flutter test exit and process cleanup. Verification-finished is not task
completion. Existing receipt, source, last-working-output and zero-reopen-effect
guards remain mandatory. Protocol16 and earlier observations retain their
original binaries and scopes; protocol17 rejects those old report versions.
This extends single-dispatch proof only: the separate multi-run retry/promotion
proof retains its existing scope and does not yet fingerprint both task histories.
There is no scheduler, automatic replay, receipt publisher authentication,
new inference or generalized CE01 acceptance.


### Native multi-run task-history proof — 19 November 2026

Disposable protocol18 includes one or two taskHistories in the bound retry
proof. Each entry binds runNumber and dispatchId, exact retained history bytes
and the typed saved-session projection. The first history preserves its pending
test/unknown outcome through explicit acknowledgment, fresh-consent retry and
promotion; acknowledgment does not invent a result or finish that history.
A second history must be absent before admission, then contain the four actual
fixed operations and verification-finished observation for its own run. These
observations still do not establish requirement-task completion.

The host validates exact bounded event rows, result types, per-run identity and
history count. Every later transition preserves the first entry; promotion and
final read-only reopen preserve both. Before-action fingerprints include nested
history maps using recursive canonical key ordering in Dart and Python. A new
protocol rejects earlier versions; the report cap is 8KiB to fit two bounded
histories. The native fixture rejects an orphan second history before admission
and requires raw history, selected session/reference and projection equality.
Existing receipt/source/output guards and zero new command/preparation counters
on read-only launches remain mandatory. Prior protocol/binary observations are
not relabelled. This is fixed isolated-fixture evidence, not a production
saved-session recovery navigation path, automatic replay, receipt authentication,
new model execution or generalized CE01 acceptance.


### Production saved-session recovery entry investigation — 19 November 2026

The native crash fixtures reconstruct their supplied ApprovedSourceProposal and
candidate-controller dependencies. Production does not yet provide that route:
AgentSessionScreen renders saved runs and task observations, and its source-review
action returns a session to ProjectWorkspace. SourceReviewController creates a
SourceCandidateController only after preparing a new candidate. Reopening that
route does not restore the prior in-memory proposal/candidate controller.
Successful fixed-fixture restart evidence must not be presented as an existing
production recorded-run recovery entry.

Retained records provide useful but incomplete context:

- CandidateVerificationRun stores number, time, GeneratedProject snapshot,
  finished and dispatchId. Its snapshot includes approval, tasks, source hashes,
  configuration and source-request provenance; it does not encode the reviewed
  SourceEditProposal before/after text or the original working-record identity.
- AgentSession and AgentTaskHistory bind approval/task selection, admitted run
  reference and observations. They do not grant execution authority or reconstruct
  a missing reviewed proposal. CandidateReceiptContext binds dispatch, source,
  approval, execution and host session; it is observation evidence only.
- ApprovedSourceProposal is an in-memory review object with project/task,
  approval, bounded proposal changes, optional repair run and request provenance.
  prepareSourceCandidate returns a prepared GeneratedProject rather than this
  envelope or its source-base snapshot. SourceReviewController intentionally
  creates candidateEvidence without repairRun after preparation; retain those
  actual semantics rather than reauthorizing against an invented failed run.
- RepairAttempt records can contain proposed changes and request provenance
  against a failed run. That is not an unambiguous binding to every later prepared
  candidate. Never select the latest repair attempt as recovery authority.
- SourceReviewController captures the exact raw working record at construction
  and rechecks it through requireWorking. SourceGenerationController promotion
  also compares expected working state, current approval and session CAS, and
  publishes generation/previous/execution records atomically. Capture the original
  working identity; taking a new baseline at reopen would erase this guard.

The next coherent product increment is explicit reopening of the latest recorded
bound candidate for a selected session, using a new immutable local reopen
context. Capture its basis during reviewed preparation: full bounded reviewed
proposal and model provenance, exact source-base and prepared-candidate identity,
original working snapshot and exact raw working-record fingerprint. Freeze the
actual prepared evidence; do not send a new model request or re-prepare a copy.
At verification admission, bind this basis to the exact project/session/task/run/
dispatch and publish it in the existing startup CAS with journal, current
candidate, execution, session reference and history, before receipt preparation
or host entry. Require expected absence and bounded prefix validation in
StudioDatabase. Context is immutable across checkpoints and acknowledgment;
a new explicitly consented run gets a separate reference. New production bound
admissions must not silently skip context after a publication failure. Existing
legacy/unbound rows remain retained and unavailable for this entry, with no
backfill from current files, latest repair attempts or task histories.

A read-only loader must match the selected session/reference, latest journal run,
current candidate and all stable source/configuration/approval fields; decode the
proposal with its original texts, preserve response-model provenance, and enforce
an explicit encoded size bound before parsing. Opening starts no model request,
preparation, command, preview, reconciliation, acknowledgment or storage write.
Older/superseded runs, missing/corrupt/foreign context and stale/cancelled authority
keep their existing history visible but grant no recovery action or unbound
fallback. The scoped initial entry is latest matching bound run only; general
historical candidate selection is outside it.

The UI should use a dedicated controller/view with owned fresh hosts and existing
candidate recovery controls. Recreate requireWorking from the captured original
fingerprint, then repeat current approval/input/session/source guards at every
explicit action. Reuse the existing acknowledgment, fresh-consent verification,
Stop, receipt and separate promotion workflows; do not interpret opening as
resume, fabricate an exit, complete a task, or change the publication point.
Promotion continues through SourceGenerationController with a separate candidate
host and atomic previous-output preservation. Dispose only owned hosts/listeners;
async opening or disposal cannot publish a controller or write after closure.

Validation must cover model bounds/unknown fields/identity/provenance, failed
startup CAS and zero host entry, immutable context on checkpoint/acknowledgment,
actual native DB close/reopen byte retention, stale/foreign/latest-run and working
record refusal, changed approval/cancellation, async disposal, legacy unavailable
and no-effect opening. Add controller/widget tests and IAB navigation on a clearly
labelled deterministic production-screen fixture, narrow/high-text layouts and
existing recovery-control guards. Run required analyze/full tests/relevant builds,
product/inventory checks, fresh exact review and CI. New actual native crash/entry
behavior needs its own current-binary evidence; protocol18 observations remain
historical. No live inference is necessary for the context/navigation slice.
This investigation changes no application code, storage or authority, and does
not complete production recovery navigation, general CE01/F20 or platform gates.


### Explicit saved-candidate entry — 19 November 2026 implementation

New bound production preparation captures CandidateReopenBasis with the original
working record fingerprint, working/source-base/prepared snapshots and complete
bounded reviewed proposal/provenance. CandidateVerificationStore binds an
immutable CandidateReopenContext to the admitted session/run/dispatch/time in the
same startup transaction as journal/candidate/execution/history, before receipt
preparation or command entry. Startup expects absence and the original working
record; subsequent checkpoints compare the exact retained context bytes. Explicit
acknowledgment also compares context and never rewrites it. Existing legacy and
unbound records receive no backfill.

CandidateReopenContextStore is read-only. It requires the exact selected current
session, approval/task membership, latest matching journal run, immutable context,
current candidate, history projection and original working identity. The only
allowed journal/candidate phase difference is justified by the existing exact
acknowledgment before/after fingerprints. Superseded, cancelled, missing, corrupt
or foreign records remain retained and unavailable for recovery.

AgentSessionScreen offers Open saved candidate only for the latest matching bound
reference. SavedCandidateRecoveryController owns two fresh distinct hosts and uses
the optional CandidateSourceInspectionHost interface. NativeGenerationHost exposes
its existing read-only checkSources through that interface. Opening performs two
source inspections and repeats retained identity after awaits; it starts no model,
preparation, verification, preview, reconciliation, acknowledgment or record write.
Unsupported hosts receive an unavailable message. Async disposal prevents late
publication. Original working authority is retained rather than rebased on reopen.

The dedicated recovery screen presents retained reviewed changes and reuses
SourceCandidateView. Acknowledgment, newly consented verification, Stop and
promotion remain separate actions, with current guards at each boundary.
Promotion uses the existing separate working controller and original selection
basis so atomic session/working-output checks remain enforced. The route blocks
back navigation while candidate work is active; Stop retains its existing control.

Deterministic browser fixtures exercise the production screens with supplied
sources and counters, not native files or inference. Protocol19 native fixtures
also inspect the production recovery controller on separate app launches while
retaining context fingerprints. Neither observation history nor an acknowledgment
is task completion, process cleanup or authority for automatic replay. General
session scheduling, task lifecycle and broader CE01/F20 acceptance remain open.


### Session task lifecycle and publication boundary — 19 November 2026

The saved session is deliberately observational. AgentSession freezes the selected
dependency-closed task graph, approval, append-only dispatch references and
cancellation intent. Its revision is the number of dispatches plus the optional
cancellation transition; adding lifecycle states inside that existing format
would invalidate current binding, history and recovery assumptions.
AgentSessionBinding validates membership and exact append-only admission. It does
not prove dependencies completed or assign tool authority. A candidate run checks
the approved operation graph, which can include several board tasks; its selected
boardTaskId is context, not proof that every criterion for that task was met.

There is already completion evidence, but its scope matters:

- AgentTaskHistory retains admitted/pending/result/interrupted/finished operation
  observations. Finished and exit0 are not task acceptance or publication.
- SourceGenerationController.promoteCandidate requires an exact finished ready
  candidate, current Plan, original working output and the matching saved session.
  Its final conditional transaction advances the matching execution checkpoint
  through reviewing/completed and writes current/previous generation. Starting a
  preview precedes that transaction; the transaction is the publication point.
  A crash after commit can leave a durable completed execution even when no
  controller success was returned. Do not describe this as missing all completion
  evidence, and never infer absence of publication from a missing UI response.
- RequirementsBoard already has manual queued/inProgress/blocked/done task status.
  It enforces prerequisite done ordering; RequirementsController reopens dependent
  tasks after scope/prerequisite changes. Board edits advance its revision, which
  is part of PlanApprovalStore.contextFor. Silently changing this board during
  promotion would invalidate the approved input. Manual done is not a retained
  session acceptance verdict or authority for another dispatch.
- Requirements have mapped named/manual/advisory acceptance checks and criteria.
  Their evidence rules remain separate. Generic verification success does not
  establish every criterion and must not fabricate a completed task.

The concrete missing prerequisite is an immutable per-run session publication
outcome: the promotion transaction CAS-checks the session but stores no explicit
record binding that selected task/reference to the exact before/after working
identity and completed execution. Current/previous generation are rotating
project records. A later promotion can replace both without providing a dedicated
session publication envelope. Existing read-only run status can display completed
execution but has no separately bound publication outcome to validate or render.

The next coherent increment should capture that narrower fact. At an explicitly
approved bound promotion, construct bounded typed publication evidence binding
project/session/task graph/approval/reference/run/dispatch, verified candidate
fingerprint, original working fingerprint, published working fingerprint and the
exact execution before/after identities. Publish it with expected absence in the
same final transaction as working/previous generation and completed execution.
Keep session v1/history/context bytes unchanged. A failed transaction publishes
none of these updates; a commit-before-return crash retains all. A new run uses a
new immutable record, never overwriting an earlier publication. Legacy/unbound
absence remains unavailable; no backfill from today's files or latest run.

Add a read-only validated projection in the saved-session UI labelled Published
candidate, explicitly separate from Task complete and criterion acceptance.
Historical publication stays visible after later runs or session withdrawal when
its exact retained binding validates; it grants no retry, dependency readiness or
execution authority. Missing/corrupt/foreign proof preserves independent history.
Do not call a prerequisite task completed merely because it has a publication.
General task lifecycle/dependency advancement still needs explicit scoped
acceptance evidence and a separately defined completion transition.

Validate strict shape/bounds and foreign identity; transaction failure and session/
approval/working races; first-record immutability across retry/later publication;
actual native database reopen; zero-write read-only projection; narrow/enlarged UI
and labelled IAB fixture. Preserve existing Stop/unknown/acknowledgment/retry and
last-output guards, native promotion/crash checks and required CI. This
investigation changes no runtime code, records, authority or model behavior.
Evidence: existing session/history/admission/promotion100 tests plus acceptance/
criterion/manual/recovery54 tests passed on the Mac. Initial attempted read used
a nonexistent development_task.dart; DevelopmentTask is actually defined in
requirements_board.dart, and the trace above uses that source.
