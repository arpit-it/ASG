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


### Bound-session publication outcomes — 19 November 2026 implementation

AgentSessionPublication retains a bounded immutable local observation for one
explicitly promoted bound candidate. It freezes the admitted session, last task/
run/dispatch reference, UTC run identity, full verified-run fingerprint, exact
original and published working-record fingerprints, and typed execution before/
after transition. The before checkpoint must be verifying and the after value
must be exactly its reviewing/completed transition. Strict shape, size, canonical
UTC, hashes and duplicate-member checks reject malformed records. These are local
correlated facts, not authenticated external exits or criterion acceptance.

SourceGenerationController computes the exact published generation encoding once.
For a bound promotion, it captures the outcome after preview validation and before
the final conditional commit. The transaction expects outcome absence and existing
session/approval/journal/execution/working identities, and jointly publishes the
outcome, completed execution and current/previous working records. A failed or
raced commit cannot publish a subset. Existing outcome bytes are never replaced
by this workflow. Session v1, task history and reopen context formats are unchanged;
unbound promotion does not invent a session outcome. No loader backfills legacy
records or guesses from today's latest files.

AgentSessionPublicationStore is read-only. It correlates canonical retained bytes
with the exact verified run and completed checkpoint, and validates the original
session as a prefix of the currently selected saved session. Later admissions and
cancellation can preserve historical publication; today's Plan/working pointers
are not a new baseline for that history. Current execution/approval guards for
actions remain separate. Missing/corrupt/foreign publication does not erase
independent run and task-history facts. It grants no retry or dependency readiness.

The saved-session screen labels valid evidence Published candidate and explicitly
separates task completion and acceptance criteria. A completed checkpoint without
valid publication gets an unavailable-evidence message. Narrow/high-text widgets
cover both states without writes. The labelled in-memory browser fixture supplies
publication and withdrawal observations, exercises production screens and refuses
writes after setup; it does not execute a model, SDK or preview.

Native protocol20 additionally requires the exact publication record/projection,
selected task/run/dispatch and actual original/published working fingerprints in
bound promotion cases. Evidence is absent before publication and retained after a
commit-before-controller-return crash and separate read-only reopen. Refused
publication must preserve the entire prior proof. Historical protocol19/binary
observations remain distinct. Full CE01 task acceptance/lifecycle and broader F20
acceptance remain open; publication never sets board TaskStatus.done.


### Published task acceptance-evidence applicability — 19 November 2026

Existing criterion evidence has a reproducible identity, but it is not the
publication fingerprint. RequirementRunIdentity.savedRunSha256 hashes sorted source
and fixed input manifests plus the saved Plan approval hash. Publication's
verifiedRunSha256 hashes CandidateVerificationRun, including dispatch, UTC time and
snapshot. Correlate these domains through the exact retained run and its source/
input/approval values; do not compare them as interchangeable hashes.

RequirementCheckReportStore currently reads the project's current saved generation
and board. It constructs RequirementRunIdentity from saved sources and approval,
compares fixed input payloads with today's application definition, and requires
current Plan approval and matching approved task graph before savedInputsCurrent
is true. Its results include the full current authored requirement and checks.
The report does not accept an arbitrary historical publication as its target.
Currentness is about saved records; it is not live file/artifact inspection.

Named and manual observations retain one latest value per requirement/check. Each
binds requirementSha256 and that savedRunSha256. Report.directCheck also requires
the exact authored check declaration and target. New observations can replace
these values; they are not an immutable session task-acceptance archive.
RequirementNamedTestRunner rechecks selected snapshot identity and confined source/
artifacts around an explicitly selected named test, dispatches once, then saves
conditionally. These protections must remain separate from a read-only review.
Opening a review must not construct a test session or call that runner/inspector.

criterionVerifiedAgainstChecks is deliberately narrower than general acceptance:
only a nonempty, unique allMappedNamedTests rule with authored automated targets,
exact requirement/criterion definitions and current saved passes qualifies. Manual
observations remain self-reported; advisory results, generic operations, unmapped
criteria, the free-form acceptance block and prose semantics remain unverified.
No criterion set may pass vacuously because it is empty. Existing board done and
session publication are not substitutes for this rule evidence.

The missing concrete prerequisite is a read-only publication-to-task evidence
review. An exact selected publication binds a frozen session task ID and
requirementId, but AgentSessionScreen has no entry that validates that identity
against the current report and presents only the corresponding authored criteria.
Opening the existing full report screen would also expose test/manual-write
operations and would silently target today's generation rather than the selected
publication unless explicit applicability checks were added.

Implement one dedicated read-only service/controller/view, with a saved-session
entry for the exact publication/reference. Validate publication through its
existing store; require current working raw fingerprint to equal the publication's
publishedWorkingSha256 and the typed saved project to equal that verified run.
Derive expected RequirementRunIdentity from the run's source/input/approval and
compare it to the report's identity. Require report.savedInputsCurrent, matching
frozen approval/task graph and exact selected task→requirement membership before
presenting criteria as applicable to that publication. Never find a replacement by
latest observation, session, run or publication. A later working publication,
changed Plan/board/input, missing/corrupt/foreign records or unavailable identity
must retain the independent historical publication while marking review
applicability unavailable. Do not retarget the route to another generation.

Present only that requirement's authored criterion rules, exact saved check facts,
manual/advisory distinctions and unverified prose coverage. Missing rules/mappings
must be visible, with no aggregate Task complete verdict. Session withdrawal can
leave read-only matching facts inspectable but cannot grant actions or dependency
readiness. Use a dedicated path with no model/SDK/preparation/preview/inspection,
manual-observation writes, test-session creation or board mutation. Revalidate
before exposing a refreshed snapshot; disposal cannot publish late state.

This bridge does not yet justify a durable completion transition. A later explicit
completion policy would need a bounded immutable evidence envelope binding exact
criterion/requirement/check values to the publication, scoped user consent,
prerequisite decisions and cancellation/approval guards in a joint transaction.
The current latest-observation stores cannot reconstruct such history after
replacement. Do not implement that policy by guessing or mutating board status.

Validate exact current applicability and independently altered publication/run/
checkpoint/session/working/approval/requirements/inputs, replaced named/manual
observations, missing/unmapped/manual/advisory criteria, withdrawal and disposal;
prove zero writes and zero host/runner construction. Add narrow/high-text widgets
and labelled IAB production-screen checks. Existing report/criterion/manual/named/
publication60 tests and named-runner/artifact/session/admission39 tests passed.
This investigation changes no runtime code, record formats, verdicts or authority.


### Exact published-task evidence review — 19 November 2026 implementation

PublishedTaskEvidenceStore reads records through RecordStorage only. It resolves
one supplied session/reference/run, validates the existing publication and
completed checkpoint, and requires the current working raw fingerprint to equal
that publication's published output. It revalidates current frozen session
approval/task membership, derives RequirementRunIdentity from the retained run's
source/input/approval values, and compares that identity and typed saved project
with RequirementCheckReportStore's current report. Report.savedInputsCurrent must
be true. A later working record cannot retarget the selected publication even
when its source/input identity happens to match.

The service snapshots relevant session/journal/checkpoint/publication/working,
project/requirements/application/approval/conversation and named/manual observation
records before loading, then compares exact bytes before returning. Reentrant
changes cannot publish a mixed projection. It never writes or constructs a host,
named-test runner, model provider or artifact inspector. A missing, foreign,
corrupt, stale or changed selection returns a sanitized unavailable result and
preserves independent historical publication. It does not guess another run.

PublishedTaskEvidence contains only immutable display facts for the selected
frozen task's requirement, not the entire report or private snapshot fingerprint.
Authored criterion rules and direct named/manual/advisory facts remain distinct;
there is no aggregate task-completion or dependency-readiness property. Empty
criteria and mappings are visibly unverified. Replacing a named observation
changes a newly loaded projection without mutating the previous display snapshot.

AgentSessionScreen offers Review published task evidence for a valid publication.
The dedicated controller/view owns a synchronous saved-record projection only,
provides read-only reload/retry and clears stale data on failure. Disposed
controllers cannot load or publish late results. Matching withdrawn session facts
remain inspectable but grant no execution/manual-write/board-change controls.
Current files are not inspected and prose semantics remain unverified.

Regression coverage includes exact authored contracts, manual/advisory/unmapped
facts, separate requirement scoping, read-only storage, independently altered
identities, valid later working output, foreign publication, replaced/stale named
results, reentrant changes, sanitized errors and disposal. The production route
and stale/retry rendering pass at320px and2x text. The supplied browser fixture
uses deterministic publication/named/manual observations, not actual SDK tests;
IAB verified scope/reload/withdrawal/legacy behavior and zero effects. Production
web and an isolated macOS app compile; no new native UI/process-crash/live-model
acceptance is claimed by this read-only review increment.


### Explicit authored-check completion decision — 19 November 2026 investigation

The existing report already supplies the narrow policy predicate:
`requirementVerifiedAgainstChecks` requires a current successful saved generation,
an exact authored requirement, nonempty criteria, and every criterion verified by
its nonempty `allMappedNamedTests` mapping. Reuse that predicate rather than
aggregating display labels or accepting a convenient subset of criteria. A mixed
manual/advisory/unmapped criterion set cannot produce this decision. The
free-form acceptance block and live files remain unverified even when all
explicit named-test contracts pass. The publication alone is never acceptance.

The concrete missing outcome is an explicit, durable user decision named
`completedAgainstAuthoredChecks`, with a bounded immutable evidence envelope.
PublishedTaskEvidence deliberately contains display strings only and must not be
parsed back into authority. A separate typed selection must capture canonical
criterion definitions/mappings/rules, exact requirement content/hash, scoped named
observations and targets/results, report source/input/approval identity, and exact
publication/run/checkpoint/session/task bindings. Include explicit consent to this
limited claim and decision time; preserve the distinction between supplied saved
observations and a newly executed SDK test. No model judgment or free-form prose
can supply the predicate. Bounds, strict decoding and exact key/payload agreement
are required; do not embed the entire unrelated report or raw private paths.

One expected-absent decision record per selected session/publication is the
publication point. The store must first obtain and revalidate a fresh typed
selection using the existing exact published-task applicability checks. The
confirmation action must bind the exact displayed selection, not reload and
silently save changed evidence. CommitRecords compares the full relevant read
set, including selected session, publication, candidate journal, execution
checkpoint, working output, approval/project/application/board/conversation,
named/manual observations, and any generation history read by the report.
Re-evaluate consent/disposal/cancellation in the transaction authorization callback.
Only the decision record is updated; session v1, working/previous output, check
observations and manual board status stay unchanged. Failed comparison, withdrawn
session, disposal or denied consent publishes nothing. An identical retained
record may be shown as already saved; conflicting content is never overwritten.
A later publication gets its own decision, preserving older decision bytes.

Prerequisites need an explicitly selected, retained decision for each frozen
session task dependency, bound to the same session/project/approval/frozen graph
and exact prerequisite task/requirement contract. Verify that decision's retained
publication/run/checkpoint and frozen named-test evidence; reject absent, foreign,
malformed or unsupported decisions. Do not guess the latest run or use manual
board Done as a substitute. A prerequisite's older published working output need
not equal the dependent's current working output: these are historical decisions
against authored contracts, not proof of current artifact compatibility. Expose
that limitation. The dependent decision itself still requires its selected
publication to match current working output and current approved graph. This
bounded slice grants no dependent dispatch or scheduler readiness authority.

Historical decisions must remain readable when observations are replaced, working
output rotates, the session grows or cancellation is requested. Show immutable
saved facts separately from whether a new decision is currently applicable;
withdrawal forbids new decisions but does not erase prior evidence. Legacy absence
is explicit and never backfilled. A retained decision must validate its own
frozen evidence and publication/session prefix without relying on the current
latest observation to reconstruct the past. New database validation and isolated
corrupt-record handling are necessary; existing transactional storage can publish
one record atomically and requires no new storage engine or session migration.

The next coherent implementation is this explicit decision model/store/controller,
confirmation and read-only history on the existing published-task route. It must
cover strict/bounded serialization, all-rule versus mixed/empty/stale/failed
refusal, exact displayed-selection CAS, altered inputs/prerequisites/withdrawal,
disposal and denied consent, duplicate/conflicting decisions, replaced observations,
rotated output, restart persistence and narrow/high-text UI. Native reopen and
commit-before-return crash checks must demonstrate absent-or-complete decision
bytes without replay or stable-app replacement; labelled IAB must distinguish
supplied check observations from real SDK execution. Existing broad checks and
required CI remain mandatory. This investigation creates no decision record,
execution authority, task-status transition, model/SDK call or semantic acceptance.


### Authored-check decision implementation checkpoint — 19 November 2026

AgentTaskDecisionEvidence freezes strict typed requirement/rules, scoped passed
named observations, content identity and exact AgentSessionPublication. A decision
adds explicit limited consent and its UTC confirmation time, using a versioned
bounded schema. It records historical completion against authored checks only;
prose, live files, current compatibility and dependency dispatch remain outside
its claim. Scoped evidence owns immutable encoded values and returns copies.

AgentTaskDecisionStore.select performs existing exact current publication/working/
Plan/session applicability checks, then reuses requirementVerifiedAgainstChecks.
A private RecordStorage wrapper captures and compares every read, including each
explicitly selected prerequisite decision and its retained proof. No selection
writes. confirm accepts only that store's frozen selection and explicit consent,
then conditionally publishes one expected-absent record; consent/lifecycle is
checked again inside transaction authorization. It updates no board, session,
working output or check observations. Identical repeat confirmation returns the
retained record; conflicting proof refuses without rewriting it.

Historical load independently validates retained publication/run/checkpoint and
frozen named-test identity, recursively checking bounded earlier-run prerequisite
references in the same frozen session. It does not use current working output,
Plan or replaceable named/manual observations to reconstruct history. New
selection still requires current working identity and exact current requirement
content for prerequisites. Production storage performs strict key/payload
validation and isolates corrupt decisions on reopen without discarding bytes.

PublishedTaskEvidenceController owns explicit prerequisite choice, consent,
confirmation state, epoch/lifecycle guards and sanitized failures. The view keeps
read-only reload separate from the optional limited decision, shows retained
criterion/named-test facts even when current review is unavailable, and exposes no
execution or board-status action. The full deterministic suite and native database
unit reopen pass. Labelled IAB and isolated native process-crash acceptance remain
pending; no new device/process/browser/live-model outcome is claimed yet.


Decision acceptance now includes labelled IAB confirmation/reload, frozen pass versus
replaced latest failure, and withdrawal with no new controls. The decision-only
fixture permits only the exact one-record expected-absence transaction; unrelated
writes are refused. Separate native protocol21 exercises a disposable root-scoped
database through precommit and postcommit-before-return process kills, then exact
reopen and withdrawal without replay. Its publication/named-test facts are supplied,
not newly executed SDK tests. Protocol20 publication smoke still passes on the same
isolated binary. These observations establish local bounded behavior, not semantic
acceptance, arbitrary execution, live inference or unavailable-platform support.


The fresh review also covers reentrant disposal during synchronous history/selection
loading: returned facts are published only while the controller is alive, and a
disposed controller performs no subsequent evidence read. A failing-then-passing
regression proves that boundary. Full2,018 tests and fresh IAB/native process probes
pass on the corrected source; earlier observations remain separately historical.


### Session-level retained-decision overview — 19 November 2026 investigation

The current AgentSessionRunStatus/Store carries each selected dispatch's correlated
candidate, execution, task history and publication, but no authored-check decision.
The session view therefore cannot distinguish recorded decision, absent decision
and unavailable proof without opening each published run. A later run of the same
task must not inherit an earlier decision or hide it behind a guessed latest run.
The smallest coherent outcome is per-reference retained-decision facts in this
existing overview, with no aggregate task Done/readiness or new action authority.

Historical AgentTaskDecisionStore.load and its recursive proof helpers use only
project ID; current project metadata, working generation, approval and latest check
observations are needed by selection/confirmation, not history loading. Extract a
read-only AgentTaskDecisionHistoryStore taking RecordStorage plus project ID,
sharing the existing strict decode, exact publication/run/checkpoint/content and
frozen prerequisite validation with the decision writer. Keeping the reader beside
the writer in the existing service file can reuse private read-set/proof helpers;
do not invent a synthetic StudioProject or duplicate a weaker verifier. The writer
continues using its typed current project and exact consent/CAS transaction. The
overview must construct only the reader, not a host or confirmation service.

Add a typed decision state (absent, recorded, unavailable) and optional immutable
decision to each AgentSessionRunStatus. Absent is valid only for an exact validated
session/reference with a genuinely missing decision key. Existing/unknown malformed,
foreign, changed or incomplete proof is unavailable, never absent or backfilled.
An unavailable run/session binding cannot assert absence. Retained decision failures
must not erase independently valid run, task-history or publication facts. Validate
the composed overview against a consistent record read-set and reject reentrant
changes rather than mixing a publication from one snapshot with a decision from
another. The overview's current ConditionalRecordStorage requirement comes from
execution-checkpoint reads; a narrow typed read path or fail-closed read adapter
must preserve all existing checkpoint identity checks without exposing write work.

Render every recorded run/reference in its saved order with the exact task/run,
limited authored-check mode and confirmation time. Distinguish no saved decision
from unavailable decision proof. Keep the existing exact-publication review route
and show that these are historical contracts, not prose/live-file/current-artifact
compatibility or dependent-execution verdicts. Replaced named observations, rotated
working output or revoked current approval must not erase a matching retained
history. Withdrawal/growing sessions use the existing frozen graph/approval and
publication-prefix checks. Multiple publications of one task remain separate.

The existing review navigation does not await its child route; a new summary would
otherwise stay stale after an explicit decision. The view should capture the exact
selected session ID, await the child route, check mounted, then request a dedicated
controller history refresh for that same selection. The controller checks disposal,
busy state and unchanged selected ID, reads that explicit session and refreshes run
facts only. Do not call the broad load/resetSelection path, switch to the latest
session, recreate task choices, consult current approval or grant work. If the
selected record is missing/corrupt, retain the last visible session snapshot with a
sanitized error and mark new decision facts unavailable instead of showing stale
facts as freshly valid. Disposal during reads or a late route return after another
selection must publish no late result and perform no unintended selection change.

The next implementation combines this reader boundary, typed per-run state,
controller refresh and production view in one increment. Regression coverage must
include recorded/absent/corrupt/foreign/missing proof, two publications of one task,
withdrawn/growing sessions, replaced latest observations/current approval/working,
zero writes/host effects, consistent reads, unchanged confirmation/CAS behavior,
scoped return refresh, task-choice preservation, failure sanitation and disposal.
Use narrow/high-text widgets and labelled IAB for the actual overview→confirmation
→return flow. Recheck native retained decision/reopen behavior if shared proof code
changes, relevant builds, full regression checks and required CI. No migration,
backfill, current semantic acceptance, scheduler or board-status update is needed.
This investigation changes documentation only and claims no new UI/runtime outcome.


### Session decision overview implementation — 19 November 2026

AgentTaskDecisionHistoryStore now shares the writer's strict retained proof path,
using only RecordStorage and project ID. Missing decisions require an exact saved
session/reference; no current project, approval, working output or check observation
is needed for history. AgentSessionRunStatus carries typed absent/recorded/unavailable
state plus immutable decision proof. The status loader captures a consistent complete
read-set through a write-refusing adapter. Decision-only corruption preserves valid
run/publication facts; changed composed records invalidate the result.

The production overview shows each saved task/run separately with limited decision
mode and confirmation time. Returning from the exact evidence review awaits the
route, guards its captured controller/mounted state and refreshes only the still
selected session. Task choices and current approval state are preserved. Reentrant
selection/disposal suppresses publication; a failed reload retains the last snapshot
with sanitized error and unavailable fresh facts. No board, session, working-output
or observation writes, execution, backfill or dependency authority are added.

Coverage includes two publications of the same task through growth/withdrawal,
rotated working/current approval, corrupt proof, read races, exact absence and
actual confirmation→return navigation. Narrow 320px/two-times-text widgets retain
readable historical limits after changed supplied evidence and withdrawal. Fresh
labelled IAB verifies the actual overview updates on return with one decision,
unchanged original records and zero unexpected writes/inspection/effects, then
retains the same decision after two explicit fixture mutations. Native protocol21
five-process persistence/crash/reopen and protocol20 five-launch bound publication
smoke pass on the new isolated binary. These establish their bounded fixture/Mac
behaviors, not general CE01, semantic acceptance or unavailable-platform behavior.


### Selected-session prerequisite provenance — 19 November 2026 investigation

In progress under #404, after the verified session decision overview. Existing
AgentSessionBinding.select validates project/task membership and withdrawal;
AgentSessionRunAdmission validates the exact saved session, current approval,
frozen graph and candidate startup identity. Neither consumes a selected
prerequisite-decision mapping. This is the existing explicit review boundary,
not evidence of dependency-ready scheduling.

AgentTaskDecisionReference binds historical task/run/fingerprint and recursively
validated authored-check proof. Decision selection compares prerequisite requirement
content to the current board, while PublishedTaskEvidenceStore requires the selected
publication's exact current working record and current input/report identity.
These checks deliberately do not assert semantic artifact compatibility. Publication
records retain original/published working hashes, and candidate reopen retains a
reviewed source basis; investigate whether an exact, bounded lineage statement can
be established, and what additional explicit provenance would be needed before any
future admission change. Run number ordering or a guessed latest decision is not
an input-provenance contract. Multiple prerequisite outputs and intervening
publications require explicit treatment rather than hash-based readiness claims.

Next: trace those proof boundaries and current regression cases, identify the
smallest useful conservative outcome or the missing contract, and specify adverse
cases/acceptance. No source implementation, automatic next-task selection, schema
change, execution grant or generic completion is delivered by this investigation.


#### Findings and next implementation boundary

SourceReviewController captures working separately from `_proposalSource ?? generated`.
CandidateReopenBasis validates the reviewed before/after hashes against sourceBase
and prepared, while only the project input manifests must match working. This is
intentional support for a separately reviewed base, including repair context.
SourceCandidateController checks the original working record and prepared candidate
before verification; candidate startup can retain the optional context atomically.
Promotion separately records original/published working hashes with completion.
Neither graph membership nor that original-working hash asserts which source base
was reviewed. Context is optional in the existing admission API, so valid legacy
publications/decisions cannot be assumed to contain it.

A disposable deterministic probe used the existing published fixture and actual
strict domain parsers. A two-publication sequence retained an exact working link
and equal preparation/prerequisite source maps. A second accepted basis retained
the same working hash and prepared output but used another reviewed before-source
with matching before hash. It passed the existing parser while sourceBase differed
from working. Thus a working-hash equality alone is insufficient. This is an
expected-contract counterexample, not a defect requiring changes to repair rules.
Probe: /tmp/asg-404-prerequisite-provenance-probe_test.dart and
/tmp/asg-404-session-prerequisite-provenance-investigation-probe.log. Supplied model
identities and fake hosts remain fixture evidence; no live model or SDK is invoked.

The smallest useful next outcome is read-only direct preparation provenance for
an explicitly selected historical prerequisite decision within the existing
published-task review. For each prerequisite in an already retained dependent
decision, use its exact task/run/fingerprint rather than choose a latest result.
Show direct recorded linkage, no direct match, or unavailable proof separately
from the unchanged historical authored-check decision. No state is called ready,
Done, compatible, accepted, eligible or permission to execute. This outcome adds
no admission gate, inference, scheduler, decision rewrite or new durable record.

The historical loader takes RecordStorage/project ID, exact current saved session
and dependent run. Share existing strict decision/publication/run/checkpoint proof;
validate the dependent decision and every exact retained prerequisite first. Read
CandidateReopenContext directly through a bounded canonical identity decoder;
do not use loadLatest, which intentionally requires current working/approval and
an active latest candidate. Match context project/task/run/dispatch/start identity,
its frozen admitted session to the dependent publication session, and its prepared
candidate to the exact completed run. A stale/repaired final snapshot that cannot
match the original context is unavailable; never reconstruct a context from output.
Use current session prefix/graph proof to retain withdrawal/growing-session history.
Capture one consistent read-set for the complete composed review, fail closed on
changes, and preserve independent decision/publication facts on lineage-only error.

Direct recorded linkage requires all of: the prerequisite publication's published
working hash equals dependent publication.originalWorkingSha256 and the dependent
basis.workingSha256; the canonical retained prerequisite working snapshot and basis
working snapshot independently match that digest; and complete sourceBase.sources
key/value map equals the exact prerequisite run's source map. Reuse existing strict
parsers before comparison. These are exact local recorded identities, not current
file inspection, external authenticity or semantic compatibility. If all proofs are
valid but the source base or working identity differs, report no direct match;
missing, malformed, foreign, inconsistent or noncanonical proof is unavailable.
The projection must expose only bounded typed states/exact reference identity,
not entire stored source proposals or tool output.

Multiple prerequisites are reviewed per edge. Different earlier outputs generally
cannot all be the same direct working snapshot. Report each edge independently;
no guessed transitive chain, aggregate verdict or automatic choice. A later approved
edit may retain behavior or remove it; byte-map identity does not establish that
behavior. New future dependency-ordered execution therefore still needs an explicit
approved input/provenance and authorization contract covering multiple inputs,
intervening/repair changes, stale current state and atomic admission. The proposed
read-only review does not satisfy that prerequisite and must not retrofit the
current decision mode into a dependency guarantee.

Implement this typed projection, strict historical service, controller read/error/
lifecycle handling and production view together. Existing retained decision review
can show its stored prerequisite rows; a root decision has an explicit no-historical-
prerequisites state. Loading/refresh must create no current approval, host, model,
inspection or write authority. Keep exact decision confirmation/consent/CAS behavior
and existing formats unchanged. Verify direct fixture link, valid divergent bases,
missing/foreign/corrupt context, wrong task/run/session/checkpoint, changed maps,
multiple publications/prerequisites, withdrawal/growth/current-working rotation,
read races, immutable projections and controller disposal/error sanitation. Verify
narrow/high-text rendering and labelled actual IAB proof with no effects. Shared
historical decoder changes require fresh relevant native reopen regression/builds;
full required local checks, exact review, required CI and verified merge remain gates.
This completes the investigation boundary only, not this future implementation.


Implementation correction — 19 November 2026: SourceGenerationStore.encodeUpdate
stores buildHistoryVersion/buildHistory beside GeneratedProject fields. The raw
published/original working digests cover that complete record. CandidateReopenBasis
retains its digest and typed working snapshot, whose toJson intentionally omits
history metadata. Re-hashing the typed projection cannot independently reproduce
the raw digest, as the new positive fixture regressions demonstrate. Preserve the
three recorded raw-digest equalities, and independently compare canonical validated
basis.working.toJson with the exact prerequisite run.snapshot.toJson plus the full
reviewed source map. Existing publication proof binds the exact run/checkpoint and
its jointly recorded working digest. Do not reconstruct omitted history or weaken
its persistence schema. This is a statement about the jointly retained records and
typed snapshots, not authenticated raw bytes or external/current file identity.
A typed working mismatch is no direct match; malformed/inconsistent record binding
remains unavailable. No raw snapshot digest is presented as raw working identity.


### Read-only preparation review implementation — 19 November 2026

PrerequisitePreparationReview is a detached immutable projection with exact
retained references and per-edge direct/no-direct/unavailable facts. The historical
AgentPrerequisitePreparationStore shares the strict decision reader, validates the
bounded canonical dependent context against its completed publication/session/run,
compares recorded raw working digests and independently validated typed snapshots
and full reviewed source maps, then checks its complete read-set. It never invokes
the current candidate loader, approval, host, inspection or any write. Missing
optional context preserves independently retained historical authored-check proof.
Each stored edge is evaluated separately; no latest result or transitive/aggregate
readiness predicate exists. Root decisions have an explicit no-prerequisites state.

The production evidence controller injects this reader, checks exact decision/run
identity, sanitizes independent preparation errors, retries on reload and guards
late/disposed/nested reload results. Successful confirmation still publishes only
its existing decision CAS; preparation failure cannot roll back or rewrite it.
The view shows exact task/run, readable fact labels and historical limits alongside
the unchanged authored-check decision. Current evidence/applicability remains separate.

Regression coverage includes the metadata-digest correction above, valid differing
reviewed bases, typed working mismatch, missing/corrupt/noncanonical/foreign context,
changed reads, multiple prerequisite edges with different states, growing/withdrawn
sessions/current working rotation, actual native database close/reopen, controller
error/disposal/reentry and 320px/two-times-text production rendering. The labelled
preparation fixture supplies two exact decisions/publications/check observations
during setup; it runs no SDK, model or preview. Explicit fixture actions change only
its reviewed base or remove optional context and withdrawal intent. Fresh IAB verifies
all three production fact states with unchanged decision/time and no new write or
execution authority. Full checks and required CI/exact review/verified merge gate
delivery; this review does not establish semantic compatibility or dependent execution.


### Session-bound initial proposal intent — 19 November 2026 investigation

In progress under #404. Initial and repair proposals share the bounded
SourceEditProposer transport, but ApprovedSourceProposer only reserves durable
RepairAttemptStore history when repairRun is present. Its initial branch keeps
active/cancelled state in memory and returns ApprovedSourceProposal. The source
review controller holds proposal/source in memory until explicit candidate
preparation/admission; its later CandidateReopenContext is not an initial model
request journal. Repair history already binds a failed candidate and consumes its
budget before transport, and must not be repurposed with an invented failure.

Trace the current pre-capture/pre-provider working/session/task/approval checks,
async response and provider cleanup boundaries, Stop/disposal and selected-session
withdrawal. Define the smallest bounded session request reservation/outcome/reopen
contract with exact recorded identities, atomic intent before provider entry and
truthful crash/transport uncertainty. A reservation cannot prove the server saw a
request or stopped; a returned structured proposal is not review acceptance or
permission to edit/execute. Preserve repair budget/history and last working output;
never replay an uncertain initial request automatically or store credentials in
project records. Existing deterministic initial/repair/source-review/session84
regressions pass; no live inference or runtime change is established by this work.
Next: specify concrete races, persistence outcomes and one implementation boundary.


Investigation boundary — 19 November 2026: SourceEditProposer parses a bounded
response and checks reported model identity before its finally block awaits provider
cancel/cleanup. A cleanup exception prevents that parsed result from reaching
ApprovedSourceProposer. Cancellation during cleanup also prevents return. Thus a
caller-visible failure does not establish no response, no request, or stopped server
inference. The disposable cleanup-failure probe supplies valid structured source,
observes provider entry, then throws during cleanup: the initial caller fails and
record writes remain exactly unchanged before entry and after failure. Existing
successful initial-proposal tests independently assert the same no-write behavior.
This is deterministic supplied evidence, not a live inference observation.

SourceReviewController rechecks working/session/task/approval after bounded source
capture and immediately before calling the proposer. ApprovedSourceProposer checks
approval/task and response evidence after transport, but accepts no selected-session
binding. The controller's immediate response publication path does not recheck the
selected session; subsequent candidate preparation/admission does. This is a gap
in request observation/current response presentation, not proof that withdrawn
sessions can execute. CandidateReopenContext is created later at candidate startup;
it cannot reconstruct whether a previous initial provider request was attempted.

The next coherent implementation is an explicit selected-session initial-request
journal and read-only request history, under #404. Limit it to initial proposals
with an explicitly selected saved session/task; keep legacy unbound initial review
and the existing real-failure repair journal semantics unchanged and labelled.
Use a new versioned bounded typed record, not RepairAttempt with a fabricated
failure, and no migration/reinterpretation of existing keys. Define strict size/count
limits, canonical serialization and exhaustion behavior before writing code: full
history fails closed before transport rather than silently dropping uncertain intent.
Do not add a scheduler, retries, model execution authority or budget-refund behavior.

Reserve after bounded source capture/input preflight and before creating/entering
the provider. One conditional record transaction must compare the exact saved
session/task selection/admission, current requirements/board and approval identity,
raw recorded working identity, selected source text fingerprints and journal prior
bytes. Recheck controller cancellation/disposal and current selection inside that
reservation authorization. Reuse the existing conditional storage contract; storage
failure/conflict or invalid input starts no provider. A final synchronous admission
check before provider entry handles cancellation after reservation by recording local
cancellation with transport outcome unconfirmed. The record means intent was saved;
it cannot prove a server received a request, even if a local provider was entered.
Source changes outside recorded snapshots require their existing inspection/admission
checks; no journal hash establishes current external-file identity.

Bind a monotonically assigned request identity to project, exact session selection,
task/requirement revision, approval, raw working digest and selected full source-map
fingerprints, request model and output ceiling. Keep raw working digests distinct
from typed historyless projections. Store no endpoint URL, credential, provider raw
error, prompt transcript or full source replacement. A returned outcome may retain
bounded structural facts (summary/path/digests and observed matching response model),
not recoverable executable proposal bytes. This deliberately delivers request
history rather than proposal restoration. Reopening shows historical facts only;
a new explicit request/review under fresh current guards is required to obtain or
prepare source. No returned fact substitutes for candidate proof or authored checks.

The typed local outcomes should distinguish reserved/unresolved, returnedValidated,
failedLocally and cancelledLocally. Every terminal observation refers to the exact
owned reservation and is committed conditionally without needing current execution
approval: observing history grants no execution. ReturnedValidated is recorded only
after successful parsing, model check, cleanup and current session/working/approval
checks. Stale/cancelled/cleanup-error paths cannot be labelled returnedValidated.
Failed/cancelled outcomes explicitly leave remote completion/stop unconfirmed.
If outcome persistence fails, preserve the original reservation as unresolved, report
a sanitized persistence error, and do not expose the result as durably returned.
Never rewrite another request or turn an unresolved reservation into failed/stopped
on reopen. No automatic replay, resume, inferred refund or active-server claim.
Keep the last working output and existing repair history untouched in every path.

Required implementation examples: reserve failure/conflict and invalid source cause
zero provider calls; cancellation/withdrawal/approval or working rotation during
capture/reservation/response/cleanup suppress late current result; a crash immediately
after reserve reopens unresolved without transport; valid response plus cleanup error
reopens a truthful local failure or unresolved if its outcome write failed; outcome
CAS races cannot overwrite another request; successful return records exact model
and source digests but neither candidate nor execution; corrupt/oversized journals and a full journal fail safely; a missing
journal initializes only through the first expected-absent reservation; native database close/reopen retains exact
facts without writes. Cover controller disposal/reentry, sanitized independent history
errors/retry and narrow/high-text production rendering. Add labelled supplied IAB
fixtures and fresh appropriate native persistence/build evidence, plus all mandatory
local checks, exact PR review, required CI and verified merge. Live inference, if
later needed, requires the prescribed exact runtime/model identity and exclusive
worker; these supplied probes do not satisfy live acceptance.


### Selected-session initial request history implementation — 19 November 2026

SessionProposalRequest and its canonical journal retain metadata only. The new
studio.sessionProposalRequests.v1.<project>.<session> record allows at most32
numbered requests and256KiB of encoded UTF-8. It stores exact session/approval/raw
working and selected-source fingerprints, task/requirement revision, model/4096
ceiling and local timestamps. Returned observations retain only changed-source
fingerprints and optional matching reported model identity. No endpoint, credential,
source replacement, prompt transcript or raw error is stored. Strict decoding binds
the key, rejects unknown/noncanonical/malformed facts and isolates corrupt request
history during native database reopen without replacing it or unrelated records.
Missing history initializes only through the first expected-absent reservation.

SessionProposalRequestStore reserves through the existing conditional database
transaction with exact approval-context/session/raw-working/journal read-set and
controller cancellation/disposal/selection authorization. Captured source text must
match the recorded working source fingerprints. Input preflight and reservation
complete before provider creation. Unbound initial review retains its legacy path;
real-failure repair requests retain their separate existing reservation/budget.
The controller explicitly supplies selected-session context for initial requests,
rechecks it after transport and suppresses stale current proposal presentation.
The proposer awaits parsing/model validation and cleanup before observing return.

Returned outcomes additionally compare the original durable context inside their
transaction, rather than trusting an adapter's cached session. A prepublication
native database regression separately updated a session behind that cache and
exposed the initial journal-only return CAS. The strengthened read-set rejects it,
retains unresolved intent and survives native reopen. Local failed/cancelled outcomes
need only the exact owned reservation, so withdrawal cannot prohibit recording an
observation. One failed terminal-write attempt leaves the reservation unresolved;
it is not rewritten as a different successful outcome by a fallback. Backward
outcome timestamps fail validation rather than being fabricated or normalized.
No observation proves the model server received, completed or stopped a request.

SourceRequestHistory renders reserved/unresolved, returnedValidated, failedLocally
and cancelledLocally facts independently of current approval or current proposal.
It makes no acceptance/execution claim and offers reload only. Reopening never
restores source or starts requests. SourceReviewController injects its reader,
retains last observed facts on sanitized errors, retries without transport and guards
disposal/nested reload/selection changes. Subsequent candidate preparation/admission
and promotion retain their existing explicit consent/current-context checks.
This implements bounded request history, not a scheduler, replay engine, execution
budget, proposal restoration or general source-generation acceptance.

The labelled ASG_REQUEST_HISTORY_FIXTURE supplies four setup outcomes, then allows
only production initial-journal transactions against deterministic source/provider
responses. Its counters separate setup, explicit requests, fault controls, withdrawal
and unexpected effects. It invokes no HTTP/model/MLX/SDK/files/preview. Native tests
use a real disposable database to exercise persistence and stale-adapter conflicts;
widget tests cover320px/two-times text and truthful empty/unbound/unavailable states.
Final builds/browser evidence, exact PR review, required CI and verified merge remain
recorded separately before declaring delivery.


### Initial-request to candidate lineage — 19 November2026 investigation

In progress under #404 after verified PR755. A returned request has an exact journal
number, but ApprovedSourceProposal and the strict v1 CandidateReopenBasis currently
carry task/approval/source/model facts without a request reference. Preparation
normalizes evidence and candidate startup binds an admitted session/run. Trace and
probe whether identical returned proposals can distinguish their initial request;
no latest/fingerprint/time inference or new execution authority is permitted.


Investigation result — the disposable two-request probe makes two explicit
selected-session requests through the production proposer and journal, using supplied
providers only. Both are returnedValidated, numbered1 and2, with identical source,
replacement, model and session facts. CandidateReopenBasis.capture produces identical
serialized bases for their identical proposed candidate. The retained evidence shape
has exactly boardTaskId/approval/proposal/responseModel/modelRequest and no request
identity. No candidate run was started and the working record stayed byte-identical.
Thus neither source/model fingerprints nor latest/time/run order can identify the
originating request. This is missing explicit recorded lineage, not evidence of an
unsafe candidate execution: existing approval/session/source/consent guards remain.

The trace also identifies two preservation boundaries. SourceReviewController
normalizes prepared evidence with a new ApprovedSourceProposal, intentionally dropping
repairRun; any new initial reference must survive that copy only for an actual initial
request. CandidateReopenBasis and CandidateReopenContext strictly decode v1 shapes.
CandidateVerificationStore binds context to reservation.next, after exactly one session
revision/dispatch append. The request's sessionSha256 describes the original raw
selected-session record, not that admitted session or a typed re-encoding. Existing
AgentSessionBinding.admitted validates their relationship. Reconstructing raw selected
bytes from admitted/typed projections would repeat the earlier raw-versus-projection
identity mistake and must not be used as proof.

Next coherent implementation: a small explicit initial-request reference carried
from the successfully persisted return through reviewed preparation, plus a new
versioned companion lineage record committed with existing candidate startup.
Keep the exact existing v1 basis/context/journal keys and formats. A separate typed
companion avoids weakening those parsers or silently migrating historical records.
This delivers a recorded request-to-prepared-candidate relationship and read-only
review, not replay, restored source, semantic completion or new execution permission.

Reference contract: version1, project/session IDs, exact request number and SHA256
of that terminal request's canonical metadata entry. Bound it to1KiB and existing
identifier/request-number limits. Produce it only after successful returned-outcome
persistence, attach it to returned ApprovedSourceProposal with the exact original
raw request-session snapshot in a bounded immutable origin bundle, and retain that
bundle across initial preparation normalization and candidate reopen/retry. The small
reference DTO stays separate from the raw snapshot. Never look it up by latest
request, timing or matching proposal content. A pure typed constructor is not authority; services validate the
exact retained request and captured flow before writes. Distinct valid identical
responses remain distinct references. This is an application-recorded relationship,
not authenticated external causation or proof of a server's loaded weights.

Proposed companion key: studio.candidateRequestLineage.v1.<project>.<run>. Retain
version, project/run/dispatch identity, the typed request reference, exact original
request-session raw record, exact raw session immediately before this candidate
admission, and SHA256 of the exact stored CandidateReopenContext bytes. Bound EACH
raw session UTF-8 to AgentSession.maxEncodedBytes (256KiB), the reference to1KiB and
the entire canonical companion to4MiB, allowing JSON string escaping of both raw
snapshots. The two snapshots may coincide for first admission; retries must not
replace the request origin with a later admitted session. No extra source bodies,
endpoint, credential, raw error or transport transcript is needed; existing reviewed
source remains in its existing context. Validate each raw session with its actual
decoder and hash exact original request bytes. Do not replace those bytes with
canonical typed projections merely to reproduce a recorded digest.

Before preparation/startup, the reference reader must require the exact canonical
returnedValidated entry; matching project/session/task, requirement/approval identity,
working raw digest, selected source subset fingerprints and exact proposed changed
replacement fingerprints/model provenance. The source map covers all captured input,
while returned paths must match the proposal's changed subset; no unchanged selected
input may disappear from validation. Require the original raw request-session hash.
The current pre-admission session must retain the same project/session/approval/task
graph, be uncancelled, contain the original dispatches as an exact prefix and have
revision growth equal to its appended dispatch count. Perform all existing current
session/approval/working/cancellation checks as well. The origin is not required to
be only one append before EVERY later retry. Preserve full existing explicit
candidate consent, source inspection, execution policy and Stop guards.
An initial reference must never be inherited by a real-failure repair response or
fabricated for legacy/unbound proposals. Those retain their existing separate paths
and explicit unavailable initial-lineage facts.

Construct the companion only after the actual run and admitted context are known.
Parse the exact pre-admission raw session, select the task and validate its ONE
new append with AgentSessionBinding.admitted against context.session/dispatch.
Separately validate the original request-session snapshot and its exact prefix/
revision relationship to that pre-admission snapshot. Context.requireRun must match
run/dispatch/start/prepared identity. In the same existing startup CAS, compare the
current request journal bytes, current pre-admission session and other existing
approval/working/read-set, require the companion key absent, and publish
companion/context/candidate/session/journal/checkpoint/task history atomically.
Use typed fixed-key reservation inputs, never arbitrary transaction maps supplied
by a view. Any changed proof/record, invalid reference, failure or cancellation
leaves startup records untouched and starts no tool. Exact-entry references survive
later journal growth without retargeting; concurrent changes during the transaction
still cause refusal and a fresh explicit check.

Historical projection: read only the explicitly referenced request entry and exact
companion/context/run/selection proof under a consistent read-set. Verify the
recorded context byte digest, request-origin-to-pre-admission prefix/revision proof
and one-append pre-admission-to-admitted relation, then show exact session/task/
request/run and source/model facts with preparation-only limits.
Do not call loadLatest, require current working/approval for a historical observation,
or choose a newer matching request. Missing/corrupt/foreign/changed optional proof
makes initial lineage unavailable independently of existing candidate history.
Legacy v1 contexts remain readable with no inferred link. Withdrawal, working
rotation and later requests do not erase or upgrade valid historical facts. A valid
link proves only the jointly retained relationship checked by the application;
it does not mean the proposal was accepted, a command ran or a requirement passed.

Implementation acceptance examples: two identical requests retain their separate
explicit references through actual production preparation/startup/reopen; journal
growth never changes the selected reference; wrong project/session/task/status,
request entry digest, model, raw working, selected input or changed output fails;
unresolved/failed/cancelled records cannot form returned lineage. Include noncanonical
but valid original raw-session bytes to prevent projection-hash substitution, exact
prefix/revision and one-append admission validation, native separately committed
stale-record races, atomic startup refusal and companion absence/corruption. Explicit
Stop/acknowledgment/retry and reopen must retain the initial reference/origin while
using the later current pre-admission session, with no fresh model request or lost
existing retry authority. Never reconstruct the origin raw bytes from the old v1
context's typed previous-session reconstruction. Test initial copy preservation
versus repair/unbound/legacy absence, partial reader errors/lifecycle,
narrow/high-text production UI and labelled IAB. Native DB reopen must preserve all
bytes without replay; relevant fresh builds/full checks, exact PR review, required
CI and verified merge gate delivery. No live inference is needed for these deterministic
cases; any later live acceptance remains tied to the prescribed runtime identity.


A second supplied probe confirms the raw-byte boundary: a valid pretty-printed
selected session is accepted by AgentSessionRunAdmission and the initial proposer.
Its retained request.sessionSha256 equals those exact raw bytes and differs from
SHA256(jsonEncode(selected.toJson())). The saved raw session remains unchanged.
Consequently typed snapshots cannot be substituted for raw selected identity when
validating the future one-append lineage. Both probes pass on verified PR755 main;
focused100/product32/inventory9 pass. This completes the investigation boundary
locally only; the proposed reference/companion remain unimplemented until a reviewed
merge admits that next task. No runtime, schema, live-model or SDK change occurred.


Premerge review correction — a third supplied probe verifies the retry distinction.
After two valid session admissions, AgentSessionBinding.admitted correctly rejects
using the request-origin session as if it were exactly one append before the second
admitted session, while the immediately preceding admission snapshot succeeds.
SourceCandidateController updates its binding after each run; saved candidate reopen
reconstructs a typed previous session solely for its existing recovery flow. Neither
is a substitute for original raw request bytes. The corrected companion therefore
retains TWO raw snapshots (origin and current admission), validates their prefix/
revision relationship, then validates one new append from admission to admitted.
The proposed encoded bound is4MiB, replacing the unimplemented single-snapshot2MiB
proposal. The immutable origin bundle must survive live retry and reopen.
This corrects a future contract before merge; no product behavior/schema was changed.
All3 probes pass; previous PR756 revision/review/CI cannot authorize this revision.


### Initial-request lineage implementation

SessionProposalRequestReference identifies one canonical returned entry by project,
session, number and SHA256, bounded to1KiB. SessionProposalOrigin retains its exact
original raw selected session, bounded256KiB. ApprovedSourceProposer exposes this
origin only after successful returned-outcome persistence. SourceReviewController
checks the exact returned proof before preparation and preserves initial origin
through normalization, while actual repairs do not inherit it.

CandidateRequestLineage is a new canonical4MiB companion under
studio.candidateRequestLineage.v1.<project>.<run>. It keeps origin reference/raw
session, exact current pre-admission raw session and exact v1 context digest.
Origin-to-admission requires matching identity/approval/task graph, unchanged old
dispatch prefix and revision growth equal to appended dispatch count; admission
to context requires exactly one append. All captured input fingerprints, exact
returned changes, model/task/approval/working identity and retained run must agree.
CandidateVerificationStore commits this fixed-key reservation with context, candidate,
journal, execution, session and task history in its existing startup CAS. Current
journal bytes and absent companion are part of the durable read-set; failures start
no tool and leave no partial admission. Checkpoints retain the companion unchanged.

CandidateRequestLineageStore historical reads join the explicitly referenced entry,
exact saved run/context and companion under consistent reads, independently of
today's approval or working record. AgentSessionRunStatusStore composes this optional
proof without erasing independent facts on failure. CandidateRequestLineageView
shows recorded preparation facts and explicit limits, with no execution controls.
SavedCandidateRecoveryController restores only a validated retained original origin
for existing guarded retry, never by reconstructing raw bytes from typed projections.
Legacy, unbound, repair and unavailable proof remain without an inferred initial link.
No existing strict v1 basis/context/request schema or current consent, source, Stop,
acknowledgment, repair or promotion boundary is weakened. Deterministic supplied
fixtures remain distinct from live model observations and external authenticity.


### Repair-request candidate lineage investigation

Started after verified PR757 under #404. Initial-return origin is intentionally
absent on actual repairs. Trace whether RepairAttemptStore attempt numbers survive
the returned failed-run evidence and preparation normalization; test two identical
repair returns without latest/content/time inference. This is a prerequisite
investigation, not a repair reference, replay or expanded execution authority.


CE01 repair-request lineage investigation checkpoint on verified PR757 main:
Disposable probe /tmp/asg-404-repair-lineage-probe_test.dart passes1 case using
two actual ApprovedSourceProposer repair requests and supplied identity providers
only. RepairAttemptStore retains proposed attempts1/2 for the same exact failed
run and identical proposal/model facts. ApprovedSourceProposal.repairRun values
are identical and carry no attempt number; initialRequestOrigin is correctly null.
A pure capture following production preparation normalization yields byte-identical
v1 CandidateReopenBasis records with only task/approval/proposal/responseModel/
modelRequest evidence fields. This probe does not execute the actual preparer or
a candidate host; the production normalization boundary is separately source-traced.
Working/latest failed candidate/session records stay unchanged; only the bounded
repair journal changes, and no execution checkpoint is created. The first disposable
probe used an unsupported directory copy parameter; corrected to the actual typed
decoder before the passing run. Focused existing repair/proposer/preparation/context
regressions81 pass. Logs:/tmp/asg-404-repair-lineage-{probe,baseline}.log.

Concrete remaining design work: distinguish an exact terminal repair attempt from
its failed-run identity and preserve that identity through actual preparation/reopen.
The existing repair reservation/outcome journal must remain budget-consuming and
independent of initial-request origin; its current journal-only transaction and
retained fields need examination before defining current session/working/source
read-set and historical proof. No latest/content/time matching, initial-reference
inheritance or automatic repair replay is allowed. A bounded explicit repair record
contract and adverse acceptance examples remain pending before implementation.
This is ongoing docs-only investigation under the retained claim, not a delivered
repair reference or a new ready task. Owner processes and unrelated edits preserved.


Repair-lineage investigation result — two supplied probes pass on verified
PR757 main. The second uses the actual production proposer and two StudioDatabase
adapters over one disposable native database. After repair reservation/provider
entry, the second adapter withdraws Plan approval durably. The first retains an old
snapshot; requireCurrent checks that snapshot and RepairAttemptStore.finish compares
only repair-journal bytes. It records proposed and returns repair evidence; reopening
the DB confirms withdrawn approval alongside proposed metadata. Working source is
unchanged and no execution checkpoint/tool is created. This establishes a missing
durable return-context comparison, not proof of executed or accepted repair.

The native probe initially used a ControlledRecords-only helper; corrected to the
production proposer constructor before both probes passed. The earlier ambiguity
probe remains a pure normalization/basis capture after actual supplied repairs,
not an actual preparation-host run. Existing focused repair/proposer/preparation/
context regressions81 pass. Native source capture separately verifies each selected
file against the failed snapshot's recorded fingerprint; those capture bytes and
manifest facts must remain distinct from current storage approval and write authority.

Next eligible prerequisite under the same CE01/#404 umbrella is one bounded
implementation: durable repair return-context guarding. Before transport, capture a
typed fixed-key context of current approval inputs, exact latest failed journal and
candidate records, current working record (including explicit legacy absence), and
selected session when supplied by the production selected-session flow. Preserve
the existing terminal-failure/current-approval/source checks. Bind the repair budget
reservation and successful proposed outcome to that context in the durable CAS;
repeat current authorization at transaction time, not just cached checks. Do not
accept arbitrary view-supplied expected/update maps. Preserve existing v1 repair
journal format and budget semantics, including all consumed reserved interruptions.

A failed successful-outcome commit must stay unresolved/reserved, with one terminal
write attempt; do not catch it and overwrite uncertainty as failed/cancelled. Local
failure/cancellation may retain truthful journal-only observations after context
changes, grants no proposal/command permission and never refunds the request. A
successful write must precede exposure of returned evidence. Real cleanup failure,
withdrawal, changed failed run/candidate/working/session, disposal and cancellation
remain distinct adverse cases. Preserve legacy read access and separate unbound
behavior without falsely claiming selected-session binding where none was captured.

Implementation acceptance: native separately committed approval, failure/candidate,
working and supplied-session races reject reserve or proposed return before transport
or exposure as appropriate; no partial journal/context/candidate/working writes or
tool starts. Inject outcome-write failure and prove no fallback terminal rewrite;
reserved budget remains consumed across reopen. Retain existing repair-budget,
model-provenance, category limits, Stop/ack/retry, preparation and promotion tests.
Use full Flutter/analyze/format/relevant builds and required CI/fresh exact review/
verified merge. This prerequisite must merge before adding any exact repair-attempt
reference or candidate companion. Candidate lineage remains a later concrete gap
under this sole queue, not an inferred link from existing legacy repair records.

Investigation is locally complete, docs-only: probes2/focused81 pass, no model, SDK,
app/runtime/schema or installed-app behavior changed. No live inference or wider
CE01/platform acceptance claimed. Publication, fresh review, required CI and verified
merge remain gates before this next implementation is admitted.


CE01 repair return-context implementation checkpoint under #404:
RepairRequestContext captures immutable fixed-key approval inputs, exact failed
run/candidate bytes, exact current working record including null legacy absence,
and supplied selected-session raw bytes. Production repair reservation/proposed
outcome include that read-set in durable CAS with current authorization; returned
evidence follows the successful write. Failed terminal commits receive no fallback
rewrite, leaving reserved budget consumed and unresolved. Local failure/cancellation
remain journal observations rather than new authority; old v1 formats are unchanged.
SourceReviewController supplies current repair session/working context separately
from initial-request origin; no repair lineage or source restoration is fabricated.

Permanent native matrix12 passes: five separately committed approval/failure/
candidate/working/session races before reservation and before return, injected
outcome-commit failure with exactly one terminal attempt, and selected legacy
working absence preserved without creating a record. Reopen retains unresolved
budget; no tool starts. An overly strict draft required a non-null working record
for selected repairs; corrected before publication, added the legacy regression
and repeated affected checks/builds. Final fullFlutter2099 passed/11 existing skips;
format537 unchanged, clean analysis, web/macOSdebugcompile, product32/inventory9
pass. Logs:/tmp/asg-repair-context-{native2,full2,analyze2,format2,web2,macos2,
product,inventory}.log. Native app compiled only, not installed/launched/replaced.
No live inference, model/SDK installs, owner-process changes or deployment.

This is locally validated implementation, not a delivered merge. Publication, fresh
exact PR review, required CI and verified remote merge remain pending; retain the
404-repair-return-context claim and resume this owned work first. Umbrella404/CE01
stay open, and dependent exact repair-attempt lineage remains ineligible until this
prerequisite merges. No independent second task is ready.


### Repair request-origin provenance investigation

Started under #404 after verified PR759. Current durable return guards preserve
authorization context but do not serialize requested task or captured input subset.
Probe those identity boundaries before defining exact repair-attempt candidate
lineage. Do not equate a failed operation category with requested task intent or
strengthen legacy facts by inference. Investigation only; no new record or authority.


CE01 repair request-origin provenance investigation checkpoint on verified PR759:
Two actual supplied-proposer probes pass, with the new durable return-context
guards active and current. Probe1 requests the same supplied repair against one
failed analyze run for Tanalyze and Ttest. Returned ApprovedSourceProposal task IDs
differ, and normalized candidate bases retain that task difference. Repair journal
entries retain distinct attempt numbers1/2, but after removing number/startedAt
their stored facts are identical: only modelRequest/number/startedAt/failure/status/
proposal exist. Both failure categories are analyze, so that category cannot prove
requested board-task intent. This is missing recorded request provenance, not an
unsafe execution or a claim that candidate bases lose their own task IDs.

Probe2 keeps requested task Tanalyze and the full failed-source manifest fixed,
but selects lib/main.dart alone versus also selecting unchanged lib/extra.dart.
The actual supplied prompts differ by that extra captured file. Validated repair
output is identical; the attempt facts (apart from number/time) AND pure normalized
v1 CandidateReopenBasis bytes are identical. A full source manifest does not reveal
which subset was captured for the request. Pure basis capture follows the production
normalization shape; neither probe executes a preparer/SDK/host or reads real source
files. Only the repair journal changes; working/candidate/session records stay byte-
identical and no execution checkpoint is created. Initial-request origin remains
null for these actual repairs. No model/network/inference or source restoration.

Probes:/tmp/asg-404-repair-request-provenance-probe_test.dart; log same-prefix
-probe.log. Existing focused context/repair/proposer/preparation/reopen regressions93
pass; log /tmp/asg-404-repair-request-provenance-baseline.log. Stronger historical
repair lineage therefore needs explicit durable requested-task and captured-input
metadata, not only a reference to the legacy proposed attempt entry. Existing
RepairRequestContext is a transient fixed-key guard and must not be misrepresented
as a persisted request-origin snapshot. Legacy records stay unknown for these facts.

Remaining investigation: define one bounded versioned request-origin metadata and
terminal reference contract, including atomic reservation/return binding, all captured
input hashes, optional selected-session/raw working identity, limits/privacy, old
format compatibility and independent read-only review. Preserve the verified durable
CAS/write-once uncertainty, budget consumption, current consent/source/Stop/recovery
and last working output. Do not infer by ordinal/time/content, reconstruct missing
intent from failure category or inherit an initial reference. No new record/reference
or stronger candidate lineage is implemented; this claimed docs-only investigation
is ongoing and must be reviewed/merged before dependent implementation.


Repair request-provenance investigation result and next contract — PR759 base.
All3 supplied probes pass. In addition to task/scope ambiguity, a third probe
confirms a new proposed attempt can reconstruct its exact canonical reserved entry
from number/start/failure and requested-only model/output settings, status reserved
and proposal null. Construct ModelRequestProvenance(model, outputTokens) explicitly:
withResponseModel(null) intentionally retains an observed response and does NOT clear
it. The initial probe exposed that mistaken helper assumption; corrected without
changing product code or relabelling response provenance. Requested version1 and
observed-response version2 remain distinct. Valid formatted selected-session raw
bytes survive the real repair flow, and their hash differs from typed re-encoding.
Never reconstruct those raw bytes from a typed projection. Logs:
/tmp/asg-404-repair-provenance-all-probes.log; focused93 remains unchanged-source
regression evidence. These are supplied providers/pure capture, not live inference,
source-file inspection, actual preparation, SDK execution or task completion.

The next coherent implementation is 404-selected-repair-provenance under #404:
durable requested-task/input provenance and independent read-only history for NEW
selected-session repair requests. Keep bare legacy/unbound repair behavior and the
strict v1 RepairAttempt/Journal/Basis/Context formats unchanged; older attempts gain
no inferred task or input scope. Existing durable repair context and one-terminal-
write uncertainty remain mandatory. Exact candidate repair linkage waits until
this provenance prerequisite has been delivered and verified.

Use a new canonical version1 companion key
studio.selectedRepairRequest.v1.<project>.<attempt>. Proposed fields: version,
projectId, attemptNumber, boardTaskId, requirementId, requirementsRevision,
reservationSha256, failedRunSha256, workingSha256 (explicit null for legacy absence),
requestSessionRecord (exact original raw selected session), sourceSha256 (ALL captured
selected inputs), modelRequest (requested-only provenance). No prompt, new source
bodies, private endpoint, credential, raw error or transcript. Bound to2MiB UTF-8;
one raw session is bounded256KiB and worst-case outer string escaping plus small
metadata fits that bound. Enforce existing valid IDs, <=8 safe lib/test paths and
SHA256 fingerprints; use exact reserved-entry and canonical failed-run digests,
and exact original working-record bytes when present. Requested model settings
keep their existing limits and ceiling; no response-model downgrade is performed.

Attempt number is the existing project-global sequence, NOT a per-session32 limit.
Require positive JSON-safe integers <=9007199254740991 for new companion/reference
identities; preserve legacy journal readability rather than silently renumbering or
changing budget rules. Validate requested task/requirement against the selected raw
session membership, its unchanged approved context/current board and actual requested
task; captured hashes must match each selected failed-snapshot source, including
unchanged inputs. The failure category is never substituted for requested task.

Construct this metadata only inside the typed reservation flow after actual attempt
number/time are known. Commit companion and budget reservation atomically, compare
companion key absent plus the verified fixed-key context/journal read-set, and expose
no provider before successful commit. If metadata/identity/size/storage/CAS fails,
write neither and start no transport. Preserve distinct explicit attempts even for
identical proposals and later journal growth. On proposed return, compare exact saved
companion bytes and full PR759 context in the same journal CAS. The companion is
immutable; local failed/cancelled outcomes retain original intent but grant no new
rights. Failed terminal writes stay reserved/unresolved; no fallback record rewrite
or budget refund. Never overwrite a preexisting/dangling companion to reuse a slot.

A separate pure returned-reference DTO may contain version/projectId/attemptNumber/
attemptSha256/originSha256, bounded1KiB. Produce it only after the successful proposed
outcome commit and exact relation validation. attemptSha256 identifies the canonical
terminal entry; originSha256 identifies exact canonical companion bytes. Validate
origin.reservationSha256 by explicit requested-only reconstruction of the reserved
entry, preserving original number/time/failure. Require terminal proposed status and
matching task/source/model/approval/failure/working facts available in the jointly
retained records. A DTO or hash match alone is not permission or authenticated cause.
Do not add or infer a repair-candidate companion in this increment; there is no replay
or restored proposal/source/verification/acceptance authority.

Historical projection joins exact origin/attempt/reference under a consistent read-
set and independently of current approval, working output or latest matching content.
Show recorded task/requirement, selected paths/hashes, requested versus observed
model and truthful intent/local outcome with explicit limits. Reserved remains
unknown; proposed does not mean accepted or repaired. Missing/corrupt/foreign or
legacy/unbound origin makes stronger provenance unavailable independently of old
repair history/budget facts. Bound rendered projections with explicit omission/count
labels when needed; never trim journals or alter consumed budgets silently. Reload
starts no request, source capture or tool and does not restore a proposal. Keep
reader failure/retry/disposal independent of active workflows and hide private bytes.

Acceptance: actual selected-session requests for distinct board tasks and captured
subsets retain their explicit differences through native close/reopen; later matching
returns cannot retarget references. Enforce canonical shape/version/duplicate and
byte bounds; bad task/requirement/session/model/failure/working/source hashes refuse
new recording/return without partial writes. Test raw formatted session identity,
requested/response provenance versions, typed reserved-entry reconstruction, all
selected unchanged inputs, actual native stale adapters, metadata/journal persistence
failures and immutable-slot races; unresolved budget stays consumed. Cover legacy/
unbound absence, independent history after withdrawal/working rotation, corrupt
optional origin preserving other facts, controller lifecycle and narrow/high-text UI
plus fresh labelled IAB. Require format/analyze/fullFlutter/relevant builds/product/
inventory, exact fresh review/required CI/protected merge and verified main. No live
inference is needed for these supplied cases; any later live evidence must verify
the prescribed runtime separately.

This completes the bounded investigation locally only: probes3/focused93, product/
inventory checks and exact publication/review/CI/verified merge remain recorded
separately. No new origin schema, returned reference or stronger repair lineage is
implemented by this docs-only change. Umbrella404/CE01 remain open; only this single
provenance prerequisite becomes implementation-eligible after the investigation's
verified merge. No independent second task is ready.


CE01 selected repair provenance implementation foundation checkpoint:
Added pure SelectedRepairRequest and SelectedRepairRequestReference models, not yet
connected to production persistence or UI. They enforce canonical strict shapes,
duplicate/version/UTF-8 and JSON-safe integer bounds, sorted immutable selected
hashes, original raw session membership/approval and requested-only model settings.
Joint attempt validation checks exact reserved reconstruction, failed-run digest,
model, mapped task and ALL selected input hashes; returned references bind terminal
entry plus exact origin digest and reject reserved/local failure/cancellation.
Constructing these DTOs is not authority or proof that a commit happened. The store
will produce them only after the atomic successful outcome in the remaining work.

Focused19 tests pass (6 new model/adverse/privacy cases,12 existing native context
guards and architecture checks); clean Flutter analysis and formatting. New fixtures
exercise actual existing reservation/outcome stores with supplied pure data but
explicitly confirm no origin record is persisted yet. Tests cover formatted raw
session identity, requested/response version separation, valid-task retargeting
refusal via origin hash, unchanged selected-input proof, malformed/duplicate/size/
integer data and sanitized JSON errors without retained private bytes. Logs:
/tmp/asg-selected-repair-model-{test2,analyze2,format2}.log. No live inference, model/
SDK effects, source restoration or execution authority.

Next: typed atomic origin reservation/proposed-return integration, native persistence/
stale/corruption cases and independent read-only history/controller/UI/IAB. Full
local regression/builds, exact review/required CI/verified merge remain pending.
Keep404-selected-repair-provenance claimed and resume this owned implementation
first. No new provenance feature is published or marked Done at this checkpoint.

Selected repair provenance is now implemented locally under #404: typed capture, atomic absent-origin reservation and exact-origin proposed-return CAS, optional returned reference, consistent bounded historical projection and independent controller/view. Existing strict candidate formats and legacy/unbound behavior are unchanged. Local acceptance is recorded in REQUIREMENTS.md; publication, fresh review, required CI and verified merge remain pending. Historical references are observations and grant no source restoration, acceptance or execution authority.

PR761 request-origin/history prerequisite verified merged2c88042857f987f4ad19ab7273de702757c4bec0 after CI44623419448 and exact review. Next claimed F20/CE01 investigation is exact repair-to-candidate lineage: trace current normalization and strict basis/context; prove distinct explicit repair origins versus equal candidate capture before specifying a separate optional companion. Initial-request lineage and all legacy formats/authority stay unchanged. See REQUIREMENTS.md for scope and acceptance.


F20/CE01 repair-to-candidate lineage investigation checkpoint on verified PR761:
Two actual supplied-proposer probes pass. Each returned repair now has a persisted
canonical origin and a valid exact returned reference. Probe1 requests Tanalyze vs
Ttest against the same supplied failed analyze run/output: origin/task IDs differ,
references differ, and normalized candidate bases keep their own task difference.
A retained task ID still does not identify the exact repair request/attempt.

Probe2 requests Tanalyze twice against the same full failed-source manifest and
identical validated output, selecting main-only vs also unchanged lib/extra.dart.
Actual provider prompts differ; PR761 origins correctly retain both distinct selected
maps and references. Legacy attempt facts excluding ordinal/time remain identical.
The current preparation normalization drops repairRequestReference; pure strictv1
CandidateReopenBasis bytes remain identical and contain neither a repair reference
nor origin digest. Thus new request history fixes request intent but does not yet
supply exact candidate historical linkage. No order/time/latest/content guess can
recover that missing relation. Pure basis capture mirrors production normalization;
no actual preparer/filesystem/source capture/SDK/host/model transport was invoked.

Only two explicit origin keys and the existing repair journal change during each
probe; original working/candidate/session records remain byte-identical and no
execution checkpoint is created. Initial-request origin stays null for real repairs.
Probes:/tmp/asg-404-repair-candidate-lineage-probe_test.dart; both pass in same-prefix
-probe.log. Focused44 selected-origin/storage/native-context/candidate-basis/store/
initial-lineage regressions pass; same-prefix -baseline.log. These supplied proofs
do not establish prepared-folder execution, accepted repair or task completion.

Read-only tracing also confirms existing CandidateRequestLineageStore and startup/
recovery hooks are initial-request-specific. Their reservation, two raw session
snapshots and fixed context identity must not be repurposed by fabricating an
initial origin. Remaining owned work: map repair preparation consent and selected
session revisions through candidate admission/retry/recovery, then specify one
bounded separate repair companion with exact request+origin+context/run identity,
atomic absent-key startup and independent consistent historical reads. Preserve
strict old formats, optional corruption isolation, legacy absence, budgets and
current source/approval/Stop/recovery. No runtime/schema change in this investigation.
Keep404-repair-candidate-lineage-investigation active; review/CI/verified merge of
its eventual contract is required before dependent implementation. No independent
second task is ready; fullF20/CE01/umbrella404 acceptance remains open.

F20/CE01 repair-to-candidate investigation result and bounded next contract — PR761.
All three probes pass, including a native durable-read guard probe and the two
supplied-proposer cases. Extended probe2 through the ACTUAL existing atomic
candidate startup transaction, without invoking a preparer, source inspection, host,
receipt or SDK. Startup appends run2 and one selected-session dispatch, persists the
strict reopen context/execution intent and preserves the two valid repair origins/
references. The persisted context still has no repair reference; neither an initial
nor repair companion is written. This distinguishes real startup-record behavior
from the earlier pure-basis observation. Startup intent is not command execution.
Logs:/tmp/asg-404-repair-candidate-lineage-final-probes.log; focused44 pass. No new
runtime behavior is implemented by this documentation investigation.

The additional native probe stores valid origin/attempt records, opens two actual
StudioDatabase adapters and replaces the origin through the second supplied adapter.
The first adapter still reads its cached old origin; pure reference/attempt checks
against that cache pass. A read-only commitRecords comparison with the exact fixed
origin/journal keys and NO updates correctly refuses the stale durable record and
leaves origin/journal bytes unchanged by the guard. Thus metadata-only cached checks
cannot establish durable freshness before preparation copies source. This is a
prerequisite for the new lineage feature, not a claim of existing source authority
or an authenticated external cause. The new service must use a typed asynchronous
fixed-key read-only conditional guard before first copy and full durable startup CAS;
no generic caller-chosen comparison map or new execution grant is introduced.

Preparation currently checks working bytes, proposal/approval, selected session and
initial origin when present; repair origin is not yet an input to that optional
initial guard. Normalization removes repairRun deliberately because a prepared
candidate will replace latest-failure evidence. Keep that removal; preserve an
explicit repairRequestReference separately in memory for new linked candidates.
SourceCandidateController currently forwards only initialRequestOrigin into startup.
CandidateVerificationStore already commits journal/candidate/session/execution/task
history/reopen context together before host entry. Extend that existing transaction
with a separate typed repair reservation; never append a companion in a later write.
Existing initial-request lineage and its strict schema remain independent.

The next coherent implementation, 404-repair-candidate-lineage under existing#404,
records and reviews exact repair-request-to-candidate linkage for NEW bound repairs.
It becomes eligible only after this contract's exact review/required CI/verified
merge. No new queue or duplicate issue; fullF20/CE01 remains open.

Use an optional canonical version1 companion key
studio.candidateRepairLineage.v1.<project>.<run>. Fields: version, projectId,
runNumber, dispatchId, repairRequestReference (the explicit PR761 returned DTO),
admissionSessionRecord (exact raw PRE-admission selected session), contextSha256
(SHA256 of exact saved canonical reopen context bytes). Bound companion to2MiB UTF-8,
admission raw session to256KiB, reference to1KiB; use existing ID/dispatch validation,
strict exact shapes/duplicate/version/canonical encodings and positive JSON-safe
run identities <=9007199254740991. Preserve older journal/context readability rather
than imposing new limits retroactively. No prompt, replacement source bodies,
endpoint, credential, transcript or raw errors in the new companion.

The referenced immutable PR761 origin already retains original raw request-session
bytes. Read that origin by reference.projectId/attemptNumber and require exact
originSha256; do NOT copy/reconstruct the origin or its raw session in the companion.
Read the exact proposed repair attempt by ordinal, require canonical terminal
attemptSha256, origin.requireAttempt, reserved reconstruction and proposed status.
Reference plus hash validation records an app relationship, not authenticated cause
or permission. Both request origin and later admission session are needed; they
may differ after earlier dispatches. Compare same project/session/approval/tasks,
uncancelled admission, exact preserved dispatch prefix and revision increase equal
to appended dispatch count. Then require exactly ONE new admission via the existing
AgentSessionBinding.admitted relation to the context session/run/dispatch. Never
reconstruct either raw snapshot from a typed re-encoding or by stripping dispatches.

Before preparation copies source, a new bound proposal carrying repair reference
must resolve and jointly validate the exact stored proposed attempt and immutable
origin against that reviewed proposal, selected session extension, current approval,
original raw working hash and failed source base. Require all selected original
input hashes, including unchanged selected files, match that failed source manifest;
match requested task/requirement and the entire canonical proposal summary/changes,
requested settings and observed response model (unknown stays unknown). The repair
journal parser does not restore proposal.responseModel; use retained modelRequest
provenance for observed identity and compare candidate proposal identity separately.
Reject a conflicting initial origin, foreign/malformed reference or missing referenced record,
changed source/model/task/working or lost raw origin before source copy. Legacy/
unbound proposals without new reference keep their existing behavior. A request
with explicit absent working bytes can remain valid request history, but cannot
claim a bound candidate context requiring exact present working identity; fail that
new linkage before copying rather than inventing/restoring a working record.
A synchronous checkActive callback can recheck captured in-process state but is not
proof that another native adapter left durable metadata unchanged. Await the typed
read-only conditional guard before the preparer starts; revalidate after awaited
work and before startup. That guard must compare not only origin/repair-journal
bytes but EVERY captured current preparation context key: approval inputs, exact
selected-session raw bytes, exact working raw bytes, saved candidate/failure journal
and source-candidate bytes from the existing fixed repair context. Validation in a
cached authorize callback is not a durable comparison of those keys. A metadata-only
conditional comparison cannot detect a separately withdrawn approval or changed
working/session/failure record. Keep this guard typed and fixed-key; no caller may
supply an arbitrary comparison scope. Recovery retries without new source copying
still use their existing current-consent/source checks and the full startup CAS. A race after a prior check cannot make filesystem copy and
storage one atomic operation: if a separate unverified candidate was already copied,
retain its path under existing cancellation/recovery behavior while refusing startup
or further effects. Never claim zero copied files for a race discovered after copy
began, and never overwrite/restore the working output.

Normalize repairRun away while retaining only the explicit repair pointer; do not
extend strictv1 CandidateReopenBasis/Context, RepairAttempt/Journal or initial-lineage
wire formats. Revalidate this pointer before startup against the normalized basis:
basis.sourceBase equals the retained failed-run snapshot; basis.workingSha256 equals
origin.workingSha256; task/approval/model/proposal and every selected before hash
match. Existing context validation remains responsible for prepared-source identity
and the admitted run. A matching latest proposal or equal candidate content never
substitutes for the explicit pointer. Reject simultaneous initial and repair origins
at new preparation/admission; never fabricate an initial origin for a repair.

Prepare a private typed fixed-key reservation capturing exact current repair-journal
raw bytes, immutable origin raw bytes, and absent new companion key. Combine those
expectations with every existing startup read-set member (working/approval/session,
reopen context/journal/candidate/execution/task history) in the same commitRecords
transaction, with existing authorization/current checks plus exact repair proof.
Require absent-key immutability and no partial update on serialization, identity,
size, storage or stale-adapter failure. Start no host/receipt/tool before successful
commit. Referenced journal growth is permitted when the exact entry still matches;
never freeze an unrelated old whole journal from request time, but compare the
captured current whole journal atomically during this startup. Concurrent append or
origin replacement during that transaction fails closed and requires fresh capture.
No budget refund or repair-origin rewrite. Existing one-terminal-write uncertainty,
Stop, cleanup acknowledgement and current execution recovery remain unchanged.

Historical review must use a consistent exact read-set of companion, saved context,
candidate journal/run, repair journal/attempt and immutable repair origin. Check
fixed key identities, both referenced hashes, failed/source/working/proposal/model
relations and the two session snapshots/single admission. Do not require CURRENT
approval/working state, latest matching candidate/request or a live session. Expose
recorded request task/requirement/all selected paths/hashes, attempted failure and
requested/observed model, linked run/dispatch with explicit observational limits.
Proposed is not repaired; startup is not a command receipt or task completion.
Missing/corrupt/foreign/inconsistent optional proof makes stronger linkage unavailable
without erasing valid session, run, source, receipt, budget or initial history facts.
Never silently choose between conflicting initial/repair companions or infer a
missing relationship. Reload performs no model request, source inspection/copy,
replay, verification or restoration of a proposal. Keep errors/retry/disposal and
bounded projections independent, with truthful omission/count labels if aggregated.

During existing explicit native recovery, preserve a repair pointer only after a
successful consistent exact optional load and revalidation around existing awaited
source inspections. Retain the original request origin and capture the actual new
pre-admission raw session for a newly consented retry/run; never derive it from the
post-admission typed projection. The new run receives a new immutable companion
with the SAME exact referenced repair origin/attempt and its own run/context/dispatch.
Missing optional legacy proof can retain existing bare recovery behavior but cannot
publish stronger lineage. Fresh consent, current source/approval/working checks,
Stop/reconciliation/cleanup and retry guards remain mandatory; no request replay,
source restoration, running-process adoption or additional execution authority.

Acceptance: actual supplied selected repairs for distinct tasks/subsets and repeated
equal returns preserve the correct explicit origin through preparation, atomic
startup, native cold reopen, later history growth and a fresh-consent retry. Include
formatted original/admission raw sessions with different bytes/revisions; valid
prefix extensions versus replaced tasks/approval/prefix/revision/cancellation;
requested-only/observed/unknown model identity; unchanged selected inputs; matching
complete proposal; wrong task/requirement/working/source/terminal/origin/context/
run/dispatch/reference; malformed/duplicate/version/size/safe-integer bounds.
Exercise real native separate stale adapters for origin/repair journal/session/
working changes before preparation/admission, immutable-slot races and transaction
failures: zero startup/host effects on refusal, no partial records, consumed repair
budget unchanged. Cover optional missing/corrupt/foreign proof preserving other
history/recovery, cancellation/disposal during awaited inspections, independent
read-only reload/error/retry, initial/repair conflict rejection, narrow/high-text UI
and a fresh separately labelled IAB fixture with zero reload effects. Require full
format/analyze/Flutter/relevant web+isolated macOS compile/product/inventory checks,
exact fresh PR review, both required CI jobs and verified protected merge. Supplied
fixtures suffice for these boundaries; unavailable-platform acceptance stays#400.

Investigation locally complete: three probes (including actual atomic startup and
native durable-read refusal), focused44, product32/inventory9 and documentation diff
checks pass. Exact publication/review/CI/verified merge follow separately. No repair companion,
preparation guard, runtime/schema change or stronger historical proof is delivered
by this contract alone. Only after its verified merge should the next implementation
be claimed and started; preserve F23-last and the marketplace/deployment gates.


Fresh pre-merge contract review found and corrected one ambiguity: durable
preparation validation must compare the entire captured current authorization/source
context as well as repair metadata. The native probe demonstrates stale-cache risk;
the acceptance matrix requires separate-adapter approval/session/working/failure
refusals before preparation. This clarification adds no runtime behavior. Re-review
the forward revised PR head and rerun mandatory CI; prior-head review is invalid.


19 November2026 — PR762 verified mergedac352a2e8c62192378cda67e7414d13f47c8aaa9,
exacttree8a230ccc7bf441debf3e06cb6287698a60e27ce8 matches all3 final docs. Fresh
reviewb5cd70439e2b603d26a075c714911c514b472fbb/base2c880428 inspected the final
contract and resolved its one pre-merge finding: durable preparation must compare
full captured approval/session/working/failure context as well as repair metadata.
Forward fix preserved published history; earlier-head review/CI were not used for
merge. RequiredCI44627495095 Flutter135925243815/Python135925244026 both SUCCESS,
every mandatory step SUCCESS; no conversations; unchanged head/base/main rechecked.
Plugin PR/main/issue404OPEN and fetchedmain/tree verified. Probes3/focused44/product32/
inventory9 PASS. Native read-only guard positive control succeeds with unchanged
records; stale-origin comparison refuses before authorize and leaves durable bytes
unchanged. Latest control log:/tmp/asg-404-repair-candidate-lineage-guard-controls.log.
No runtime/schema behavior changed by the contract. One review rework, no escaped
defect observed; timing remains coordinator/manual evidence, not provider timing.
Coordinator merged/outcome_verified recorded before integration and writer release.

Immediately claimed F20/CE01 implementation404-repair-candidate-lineage from verified
main in the existing registered worktree,33 literal paths under existing#404.
Started pure CandidateRepairLineage codec: separate version1 key/7-field2MiB record,
explicit PR761 reference, exact256KiB raw pre-admission session, context digest,
project/run/dispatch identity and JSON-safe ordinal. No duplicate original session
bytes: original request session remains in the referenced immutable origin. Reject
foreign/unsafe/duplicate/version/shape/bound/canonical data with sanitized private
JSON errors. These codecs alone prove neither a stored relationship nor authority.
No persistence registration/transaction, joint origin/context validation, preparation
or recovery wiring, UI or stronger historical relationship is implemented yet.

Foundation16 focused tests pass (4 new codec/privacy/adverse cases plus existing
origin/initial-lineage/architecture checks); clean Flutter analysis and formatting.
Global run35 is accepted by the new codec, avoiding a false per-session32 bound.
Logs:/tmp/asg-repair-lineage-model-{test,analyze,format}.log. Supplied pure fixtures
only; no live inference, SDK execution, source copy/restore, stable replacement,
provisioning or deployment. Owner-started processes and unrelated dirty edits stay
preserved. FullF20/CE01 and umbrella404 stay open; #400/F23-last/marketplace gates
remain. No independent second task is ready.

Next owned work: joint exact origin/attempt/basis/context/session validation, then
typed full durable preparation guard, immutable atomic startup reservation, native
storage/race/retry tests and independent historical review. Full regression/builds/
IAB/exact PR review/required CI/verified merge remain pending. Keep the new claim
active and resume it first; no partial implementation is marked Done or published.


F20/CE01 repair-candidate lineage implementation checkpoint — PR762 base.
Added pure joint origin/attempt/evidence/failed-source/working/context/run validation,
request-to-admission session prefix/revision checks and exactly one new admission.
Canonical proposal summary/changes and requested/observed provenance are compared,
including unchanged selected input hashes. Retargeted origin, changed context digest
with wrong working/summary, altered terminal entry, bad extension or wrong admission
cannot inherit proof. Unknown response identity remains unknown. Pure retained-record
fixtures may represent different requested/observed IDs; actual request transport
continues rejecting a reported model mismatch before returning a proposal.

Added typed CandidateRepairLineageStore: exact explicit lookup; asynchronous
read-only conditional preparation comparison of ALL fixed repair context keys plus
origin/journal; private immutable startup reservation; independent consistent exact
historical join. New optional schema/key validation is registered and isolated in
StudioDatabase. SourceReviewController awaits the full durable guard before copying
and again after preparation, retaining a separate candidate path on later refusal;
normalization keeps the explicit repair pointer while removing repairRun as before.
SourceCandidateController forwards that pointer. CandidateVerificationStore commits
the new absent-key companion with its existing journal/candidate/session/execution/
task-history/context startup transaction before host/receipt entry. Initial and repair
origins conflict; each new linked startup also refuses an occupied opposite-origin
slot. Old formats and no-reference callers retain existing behavior.

Native preparation matrix8 passes: positive unchanged comparison plus separate
adapter origin/repair-journal/approval/session/working/source-failure/candidate-journal
changes refuse before authorization. Every durable record is compared before/after
the guard: no writes or added records. Atomic startup6 cases pass: success, failed
write, origin race, occupied repair slot, occupied initial slot and simultaneous
origins; refusal retains all records (apart from explicit injected race) and creates
no partial startup. One additional actual native linked startup/cold-reopen test
retains exact pointer/raw pre-session after current approval withdrawal and working
byte rotation; optional corrupted companion is isolated while journal/origin/working
facts remain readable. Historical read also refuses conflicting origins independently
of current state. These are supplied providers/pure contexts/native DB transactions,
not command receipts, actual SDK execution, prepared-folder acceptance or live model.

Two new fixture setup mistakes were corrected under existing guards: prepared data
retained old working verification steps and was correctly refused as not fresh;
reset its evidence to a new unverified candidate. A test-only different response
model was correctly rejected by SourceEditProposer; restored matching supplied
transport identity, retained differing identities only in pure historical DTO tests,
and included the existing mismatch-refusal transport suite in the rerun. No guard
was weakened and earlier fixture/model observations were not relabelled.

Latest focused184 pass, clean Flutter analysis and focused formatting/diff checks.
This includes9 actual native cases,6 atomic startup cases, pure model/metadata and
existing controller/startup/initial-lineage/transport/architecture regressions.
Logs:/tmp/asg-repair-lineage-startup-test4.log,
/tmp/asg-repair-lineage-startup-analyze3.log and same-prefix -format.log/-format2.log.
No owner process stopped, stable app replaced, model downloaded or deployment done.

Remaining owned work: dedicated selected-repair controller adverse-path integration
coverage, preserving the optional pointer around awaited recovery inspections and
fresh-consent retry, independent run-history projection/UI and fresh labelled IAB,
then full regression/build/product/inventory, exact review/required CI/verified merge.
The implementation remains unmerged/unpublished and404-repair-candidate-lineage
stays claimed. FullF20/CE01/umbrella404 and deferred400 acceptance stay open.


404-retained-repair-copy local implementation started: SourceReviewController now
exposes only a separate directory string when a returned copy differs from the
retained prior session result and preparation is no longer active. The existing
candidate getter/session/verification authority remain unchanged. Production source
review labels the second path as an unverified repair copy retained after preparation
stopped and explains that it was not admitted to a new verification run; the old run
still refers to its original folder. No new buttons, replay, writes, promotion,
startup or source restoration are introduced by this path projection.

Actual controller success/before-copy/after-copy/cancel/dispose cases assert that
only the post-copy refusal exposes copy2 while public candidate/session still refer
to copy1. Production screen projection/layout regression at320px/2x text shows
working, prior-candidate and refused-copy paths separately. Test setup was corrected
to scroll the actual outer ListView and let the screen own controller disposal;
production behavior was not weakened to satisfy the test. Focused controller/screen/
architecture76 pass, clean analysis and focused formatting. Logs:
/tmp/asg404-retained-copy-final-focused.log,
/tmp/asg404-retained-copy-final-analyze.log,
/tmp/asg404-retained-copy-final-format.log. No actual copy/SDK/model ran.

Remaining owned work: fresh relevant browser observation, inventory regeneration,
full regression/web/isolated macOS compile/product/inventory, exact scoped publication
and fresh final PR review/requiredCI/verifiedmerge. This new fix is dirty, uncommitted
and unpublished; keep its lease active and resume it first. FullF20/CE01/umbrella404
and deferred400 stay open; F23-last/marketplace/deployment gates remain. Primary
owner3IDE/3canonical-doc edits and owner-started processes remain untouched.


404-retained-repair-copy final local acceptance — all9 scoped files.
The final UI guidance uses plain language: "This copy has no new check results.
The results below still belong to the earlier folder." It appears only for a
separate returned copy after preparation is no longer active; it exposes a path,
not another run, restored proposal or execution/promotion permission. Existing
candidate/session result and controls remain on their original directory. This
slice preserves an in-memory retained-copy path; it does not add durable orphan-copy
history or automatic cleanup/recovery. No changed wire format or new storage write.

Focused77 passed (actual controller adverse paths, production320px/2x text view and
new browser fixture initialization); full final2174 passed/11 existing skips,
production and fixture analysis clean, format550 files. Production web and isolated
macOS debug compilation pass; no native app launched/installed. Product32/inventory9
pass and comparison inventory regenerated for exact final runtime. Logs:
/tmp/asg404-copy-fixture-test.log,/tmp/asg404-copy-full-test2.log,
/tmp/asg404-copy-final-analyze2.log,/tmp/asg404-copy-fixture-analyze2.log,
/tmp/asg404-copy-final-format2.log,/tmp/asg404-copy-web-build2.log,
/tmp/asg404-copy-macos-build2.log,/tmp/asg404-copy-product2.log,
/tmp/asg404-copy-inventory2.log. Initial full2174/builds passed; the plain-language
text refinement was then retested/rebuilt rather than reusing the earlier bundle.

Fresh final IAB9141 observation of separately labelled
ASG_RETAINED_REPAIR_COPY_FIXTURE shows working/previous-candidate/new-copy paths
independently in production SourceReviewScreen, truthful unverified-copy guidance
and no copy-specific check/promotion controls. Open/return leaves all records
unchanged and writes/captures/providers/inspections/tools0. Artifact:
/tmp/asg404-copy-iab-observation2.json; this is a supplied detached read-only UI
projection, not actual copy/refusal/native execution. Actual controller regressions
separately prove refusal ordering and the path projection. Older fixtures and their
identities remain unchanged. Final bundle SHA256: 80802aa696963323d7c0703fba8e50d67c81e6bbf59fb784869bd558a3b24fc4.

Local diff/failure-order review passes. Exact scoped commit, serialized publication,
fresh final PR review, requiredCI and protected verifiedmerge remain mandatory.
FullF20/CE01/umbrella404 and deferred400 remain open. No actual model inference,
source restoration, stable app replacement, owner-process stop or deployment done.


## Native repair-candidate lineage investigation — 20 November2026

Owned F20/CE01 track404-native-repair-lineage-investigation follows verified PR763
lineage delivery and PR764 retained-copy UI fix (merge2e8755fe/tree64685d19). This is
supporting contract/evidence work; REQUIREMENTS is the sole task queue. No new native
mode, process observation or implementation is delivered yet.

Current source audit: native_candidate_crash.dart constructs reviewed proposal/basis
manually and never supplies SelectedRepairRequest, repairRequestReference or
CandidateRepairLineage. On later launches its makeController factory rebuilds review
evidence from decoded strictv1 basis, intentionally lacking optional pointers.
Production SavedCandidateRecoveryController is the separate current path that loads
and revalidates optional proof around existing awaited source inspections, then
passes the original exact reference into a newly consented retry. Thus existing
protocol20 session/crash and protocol21 task-decision binaries cannot demonstrate
new repair lineage or pointer preservation. Keep all original observation identities.

Local baseline: native host56 and focused lineage/nativeDB/recovery/architecture55
pass on verified main. Private source/protocol probe confirms no new fixture wiring
and no lineage interpretation of protocol20 extension fields. Source SHA256
native fixture d1ca5cfd4fd58346695ba4d9f8c2230c67106f40ea192c55c94f578c117c9122;
host parser7c74afb71d429a7bf1c4961bfe4682ae56f941c066fc4de4ddd54d6052138663.
Logs:/tmp/asg404-native-repair-lineage-{merged-host,merged-probe,focused}.log.
These are static/supplied/native-database tests, not new app crash observations.

Proposed bounded next mode, subject to completing this investigation/review: use a
strict separate protocol (proposed22) and fixed supplied model/proposal identities;
never relabel20/21 or fabricate an initial-request origin for repair. Create a real
selected proposed repair through the existing service, retain exact origin/attempt
and consumed budget, and use production bound startup plus explicit production
recovery for retry rather than rebuilding a pointer from basis or dispatch order.
Pause before atomic startup and after committed startup but before startup returns
to any receipt/host entry. Owned fixture crash/relaunch must show complete absence
or complete joined companion/context/session/run/execution/task records, never a
partial write. Read-only reopen validates exact origin/reference hashes, failed
source/working/proposal/model tuple, context and actual raw pre-admission session.
It starts no model, capture, copy, SDK, receipt preparation or preview.

New reports should contain bounded nonsecret identities/hashes/counters and strict
mode/version/nonce/launch shapes. Proposed adverse cases include old/wrong version,
foreign run/project/session/dispatch, changed origin/terminal/context or occupied
opposite-origin slot, and corrupt optional companion preserving bare core facts.
A later explicitly consented retry must keep the SAME repair reference but use its
new run/context/dispatch and actual new raw pre-admission session. Existing source,
approval, working, Stop/reconciliation and execution checks remain mandatory. No
inference from latest/content/time, replay, source restoration, running-process
adoption, generic commands or expanded authority. Native process launches and their
exact binary/record evidence belong to the later implementation acceptance, not this
contract. Remaining: settle report/read-set/failure matrix, validate useful probes,
fresh exact review/requiredCI/verifiedmerge before claiming dependent implementation.


## Native repair lineage protocol contract — investigation result, 20 November2026

F20/CE01 track404-native-repair-lineage-investigation is locally complete as a
bounded contract, subject to fresh review/requiredCI/verified merge. Its dependent
implementation is404-native-repair-lineage-fixture under the SAME umbrella404.
No runtime/fixture mode or new native-process acceptance is delivered here.

The current AdmissionCommitBarrier calls the authorization guard and pauses before
its delegated transaction; it does not provide an after-commit seam. A disposable
private probe adds two fixed companion-key pause points around the ACTUAL existing
CandidateVerificationStore.start transaction on StudioDatabase. Before commit,
the entire physical records store equals its captured baseline. After commit,
exactly7 updated records form one cohort: candidate checks journal, source candidate,
selected session, execution checkpoint, task history, reopen context and repair
companion. The whole physical store equals baseline plus those7 updates. A new
native adapter independently loads the exact joined proof and actual raw pre-session.
In both pauses the startup future has delivered no result, so its caller continuation
has zero entries; releasing with a supplied error changes no durable record. Repair
journal/origin and working bytes remain unchanged. Both actual native database seam
probes pass:/tmp/asg404-native-repair-admission-probe_test.dart and same-prefix.log.
No process was killed and no host/receipt/SDK was invoked. Do not relabel this as an
actual application crash/reopen observation or a proof of OS process cleanup.

The next coherent implementation adds a SEPARATE opt-in native mode and strict
protocol22, preserving existing candidate/session20 and task-decision21 identities,
reader semantics and old fixture observations. Never append unrelated fields to an
old report and call it new lineage proof. Reject old/future versions, duplicate JSON
members, unknown/missing fields, wrong mode/nonce/launch/boundary, unsafe paths and
mixed incompatible legacy flags. Keep the existing bounded report/file/challenge
and owned-process protections. No new install, model download or app replacement.

Setup is explicitly supplied metadata/source, not live inference or SDK success:
use an actual ApprovedSourceProposer selected repair with a deterministic injected
provider, matching neutral fixture requested/observed model ID, and a complete
recorded supplied failed candidate. Preserve its explicit returned reference,
immutable canonical origin/proposed attempt, original raw request session, all
selected before hashes, full failed-source/working/model/proposal identity and
consumed budget. A prepared fixture source folder may be supplied and fingerprinted;
this mode does not establish the production source-copy routine or live model return.
Use current production service validation and bound candidate startup with fresh
verification state; never fabricate initialRequestOrigin or infer the repair pointer
from latest/time/content/run order. The fixture must identify supplied setup effects
separately from effects after startup. No HTTP/model transport or actual SDK command
is required for this bounded acceptance.

Fixed stages and expected observations:
- Precommit scenario, launch1: new linked startup is held before the delegate write.
  Original repair origin/attempt/working and failed run remain; all new run/context/
  execution/task/companion slots are absent, selected session unchanged. No startup
  result, receipt preparation, model transport, SDK or preview after the pause.
  Host terminates only its own nonce-bound fixture app after the ready report.
- Precommit launch2: independent process/database read-only observation matches the
  entire baseline and proves no new dispatch or companion. It never tries to resume
  verification, restore a proposal or refund the consumed repair request.
- Postcommit scenario, launch1: hold after the delegated atomic commit, before its
  future returns. All7 startup records and the exact repair reference/companion are
  durable, with expected single session admission. Original repair and working bytes
  unchanged. Startup result/receipt/SDK/preview not delivered. Kill only owned app.
- Postcommit launch2: independently reopened app/adapter loads the joint proof through
  production historical readers, with exact request/terminal/context/run/dispatch/
  raw-admission relationships. No host construction, source inspection, proposal
  restoration, model/copy/SDK/preview or new record write in this read-only stage.
- Postcommit launch3 (explicit retry variant): open through production
  SavedCandidateRecoveryController, with its current source/working/approval/session
  checks, then explicitly consent to a fresh retry. Do not reuse the legacy factory
  that rebuilds evidence solely from strictv1 basis. Preserve the original SAME
  repair reference/attempt and actual current pre-admission raw session; commit a
  new run/context/dispatch/companion. Hold its startup return again before any
  receipt/SDK/preview. No new proposal, transport, copy or repair budget consumption.
  Existing Stop/reconciliation/acknowledgement requirements apply whenever required
  by recorded state; do not fabricate a pending command merely to force a dialog.
- Postcommit launch4: read-only independent reopen validates both retained companions,
  the shared unchanged original request/attempt, distinct run/context/dispatch and
  the actual new raw pre-admission session. It starts no retry and writes nothing.

Use private fixed per-nonce fixture roots, baseline/prepared source folders and
native database outside candidate/tool write scope. Record the exact compiled
binary SHA256 and source manifest, challenge/nonce, process ownership and artifacts
for every actual new scenario. Do not terminate an owner process or adopt/kill a
process by saved PID. Preserve old binaries/results and keep skipped or failed new
observations unknown. Compile-only and same-process DB probes are not replacements
for the new separately launched native acceptance.

Concrete report/read-set contract: strict bounded protocol22/mode repair-lineage;
nonce, launch1..4, boundary precommit/postcommit, stage (paused/read-only/retry-paused/
retry-read-only), exact project/session/run/dispatch, proof state absent/joined/
unavailable and the explicit existing reference DTO (project/attempt/origin hash/
terminal hash). Retain separate hashes for original raw request session and actual
raw pre-admission session, companion and context. Report fixed before/after record
hash maps for the7 startup cohort plus original repair origin/journal and working;
retry maps also include both runs' immutable execution/task/context/companion slots.
Use null only for genuine absent values and strict lowercase64-hex hashes otherwise.
A cohort digest cannot substitute for these fixed member identities. Validate the
joined proof with current production readers; do not label arbitrary matching hashes
authenticated or a task completion. Preserve a digest of unrelated records and
working/source hashes. No raw session, prompt/source body, endpoint, credential or
private exception text in reports. Reuse the existing8KiB report bound only if the
fixed schema demonstrably fits; otherwise explicitly bound and test a new-mode-only
limit, never silently widen legacy readers.

Counters must distinguish deterministic setup provider/source actions, explicit
recovery source inspections and post-pause/cold-read effects. Required cold-read and
post-pause write/startup-return/receipt/transport/copy/SDK/preview effects are zero;
initial durable startup writes are the declared7-record cohort, not zero total writes.
Production recovery inspections on retry are expected and cannot be relabelled zero.
Report unknown honestly; host acceptance checks exact stage-specific values and
across-launch identities, not report status strings alone.

Failure matrix for implementation: wrong/old/version/mode/nonce/launch/boundary and
mixed-mode flags; malformed/duplicate/extra JSON, invalid optional/hash/DTO/run IDs;
foreign session/dispatch, changed origin/terminal/context/raw admission, selected
input/model/proposal mismatch; occupied repair or opposite initial slot and failed
transaction; no partial startup or new host effects on refusal. Preserve current
repair-journal growth behavior when the EXACT referenced entry still matches.
For optional companion corruption, use a separate explicitly labelled disposable
fixture-control case after valid committed evidence: only the calculated companion
slot may change. Reopen must keep bare session/run/source/budget records intact,
stronger lineage unavailable, no inferred alternative, no effects. Separate that
intentional control mutation from read-only counters and retain the valid baseline.
No generic caller-chosen DB keys, commands or scope in the challenge.

Required implementation checks: strict host parser/mode-confusion fixtures, Dart
new-mode preflight and private native seam controls; actual owned Mac precommit and
postcommit/reopen scenarios, explicit production-recovery retry/reopen and optional
corruption isolation; relevant legacy native scenarios on the exact new binary.
Then full format/analyze/Flutter/web/isolated macOS build/product/inventory, exact
fresh PR review, both required CI jobs and verified remote merge. No generalized
CE01, platform400 or live inference acceptance is inferred. If the expected native
seam cannot be reached, keep it pending with actual missing-stage evidence and fix
that bounded fixture; never weaken current production guards to force acceptance.


Protocol22 fixed fixture values/counter clarification: start from one explicitly
supplied finished failed run1 and one proposed selected repair attempt1; selected
session has revision0/no dispatches. Linked startup is candidate run2/one admission,
revision1; optional retry is run3/second admission, revision2. Initial failed run1
is explicitly unbound; this does not fabricate an initial-request lineage or claim
the whole production UI workflow. All actual source/approval/project fingerprints
must validate through current services. Use neutral matching supplied model ID
supplied-native-repair-lineage-model; no live inference or loaded-weight claim.
Original request/pre-admission raw session hashes match at run2; retry must use the
actual stored revision1 pre-admission raw bytes, while origin raw revision0 stays
unchanged. Do not synthesize either raw snapshot by stripping typed dispatches.

Report22 must validate exact fixed run/attempt/task/session identities and stage
values, not merely positive counters. Cold read-only launches2/4 have zero host
construction, source-inspection/copy, startup, receipt preparation, live-model
transport, SDK, preview and record writes. Launch1 setup has exactly one supplied
provider return and explicitly declared fixture-source/failure creation before the
baseline; after either pause all caller/startup-return and host effects stay zero.
Launch3 production recovery expects two checkSources calls (working and candidate)
and two distinct owned inspection hosts, then exactly one newly consented startup
whose return is withheld. No new supplied proposal/provider call or source copy on
retry. The7 declared startup record updates are not zero total writes; report them
separately from zero unrelated writes. Do not label setup source creation or recovery
inspections as zero. Keep receipt/SDK/preview/transport0 at every stage of this
bounded metadata/recovery mode. Real command receipt/process cleanup evidence stays
with the existing separately labelled native scenarios.

Investigation checks pass: two actual native DB transaction-pause probes, source and
three protocol20 evidence-scope probes, focused55, host56, product32 and inventory9.
Private regenerated inventory at /tmp/asg404-native-lineage-contract-inventory.json
leaves canonical runtime inventory unchanged because no runtime source changed.
Relevant native probe:/tmp/asg404-native-repair-admission-probe.log. Host/product/
inventory logs:/tmp/asg404-native-lineage-contract-{host,product,inventory}.log.
No production/fixture code changed, no app or process launched/killed, no model/SDK
ran. Documentation-only checks may reuse unchanged runtime build evidence; both
required remote CI jobs and fresh exact review remain mandatory. Next: publish this
three-doc bounded contract, verify merge, release the investigation claim, and
immediately claim/start404-native-repair-lineage-fixture. FullF20/CE01/umbrella404,
#400 and all other unmet acceptance remain open.


Fresh PR765 contract review correction — captured versus durable identity.
The before-commit native probe already has a fully encoded run2 companion/context
in its captured update map, while neither record exists durably. Therefore report22
must not overload planned target IDs/hashes as proof that startup committed.
Use separate targetRunNumber/targetDispatchId (fixed planned2 or3) and
committedTargetRunNumber/committedTargetDispatchId (null until that exact target is
found in the retained journal). A retained earlier failed run1 is not the target.
capturedAdmissionSessionSha256 hashes the actual pre-admission raw session read for
the reservation; it exists even before commit. durableAdmissionSessionSha256 is null
before commit and comes only from the decoded stored companion after joint validation.
The original request raw session hash remains a third distinct origin observation.
Context/companion durable hashes are null when their fixed stored slots are absent;
never substitute the captured pending-update bytes. On joined committed/read-only stages,
all durable fields must match the exact stored joined proof and declared target.
Report file/baseline artifact writes are fixture instrumentation; zero record writes
means zero native database record updates in read-only stages. Keep their counters
separate, and compare baseline artifacts against the previously captured host facts.
The strengthened two native seam probes pass and explicitly distinguish captured
companion bytes from absent durable context/companion. Log:
/tmp/asg404-native-repair-admission-review-probe.log. This clarification adds no
runtime/schema implementation; forward revised review/CI are mandatory. Previous
head approval is not granted and previous-head CI cannot authorize the revised merge.

For an explicitly corrupted optional companion, fixed raw record hashes may remain
present as observations even though stronger proof is unavailable. Keep proof state
unavailable and derived durable admission/relationship fields null unless the full
join succeeds. A physical opaque record hash is neither absence nor validated
lineage. Independent core target run/dispatch facts remain readable from the journal;
never invent their stronger relation. Retain this corruption control separately from
successful joined-stage comparisons and preserve unchanged core record identities.


404-native-repair-lineage-fixture implementation checkpoint on verified PR765.
Root added a pure typed NativeRepairLineageChallenge in the NEW isolated fixture
module and new preflight tests. It accepts only exact6-key4096-byte new-mode input;
strict mode/nonce/int launch/boundary/control/SDK fields; unknown/missing/duplicate/
UTF8 oversize/mixed legacy values and unsafe relative/non-normal SDK paths fail
with sanitized errors. Derived target run/dispatch/companion identities are explicitly
planned values, with no committed-proof fields or execution/storage authority.
Corruption control is restricted to postcommit read-only launch2. No native main
entry is wired yet, so no new mode or native-process result is claimed.

Ten focused preflight+architecture checks pass, general Flutter analysis and direct
new-fixture module analysis clean, focused format/diff checks pass. Logs:
/tmp/asg404-native-lineage-preflight-test.log,
/tmp/asg404-native-lineage-preflight-analyze.log,
/tmp/asg404-native-lineage-preflight-fixture-analyze.log,
/tmp/asg404-native-lineage-preflight-format.log. These are pure input guards, not
actual process ownership, durable startup or native crash/reopen acceptance.

Delegated host writer claimed its3 Python paths in separate Git-registered worktree
/Users/arpitsinha/.codex/worktrees/404-native-repair-lineage-host/ASG, branch
404-native-repair-lineage-host. Managed create/attach both hit the existing chat
attachment limit100; the clean registered Git worktree and coordinator claim exist,
so scoped work proceeds explicitly there. No parent writer files were shared. Status
confirms exactly2 active writers, root asg404 and host asg404-host, no integration
lock. Root owns native launch/build resources; host tests mock those actions.

Host report schema agreed at /tmp/asg404-native-lineage-report-schema.json, SHA256
c4ca8bbd88c1898e3a5cf3880a93427aacc9c7be6d22b12642f73bdfae008790:35 exact top
fields,14 fixed record slots,16 counters, existing5-key reference and8KiB report.
It separates captured/durable target and pre-session facts, raw slots from joined
proof, fixed setup/cold/recovery effects and across-launch comparisons. Cold source
manifest digests are recorded metadata; any independent host physical source checks
must be labelled separately rather than counted as new app inspections. Host writer
is implementing parser/driver/negative-case fixtures and will stop edits for handoff.

Remaining owned work: wire actual native mode and fixed setup/record reports,
integrate tested disjoint host handoff, build isolated native binary and run owned
precommit/postcommit/cold-read/retry/corruption plus legacy scenarios with exact
source/binary/artifact identities. Then full required local checks, fresh exact PR
review, both mandatory CI jobs and verified merge. Current implementation is dirty,
unpublished and incomplete; keep valid leases and resume owned tracks first. No
model/SDK/tool/app process, source copy/restore, stable replacement or deployment ran
for this checkpoint. FullF20/CE01/umbrella404 and deferred400 acceptance remain open.


Implemented opt-in native repair-lineage mode22 now uses fixed supplied proposer
metadata and actual native startup/cold historical readers/recovery. Final cold
launch validates both retained companions independently. It is never production
bootstrap or a live-inference/SDK-result claim. Owned Mac scenarios and legacy20/21
smokes passed on bundle b8a7522ce95e1694b665f9ab1172554f96a0a9634c227d434bb0d43be5ab41c2;
see canonical requirements/progress for exact private report digests and limits.


## Native initial-request lineage investigation —20 November2026



Initial native-lineage investigation checkpoint: focused29 tests PASS across
candidate_request_lineage model/store, saved candidate recovery and architecture;
/tmp/asg404-native-initial-lineage-focused.log. Includes existing native DB
stale-adapter/close-reopen and historical optional-proof isolation; not29 separate
native app processes. Source inventory demonstrates the missing app-mode initial
join without claiming that absence alone proves a product defect.

Production mapping: CandidateRequestLineage has strict canonical8-field v1 companion
with exact requestReference, original raw requestSessionRecord, actual immediate
admissionSessionRecord, contextSHA and run/dispatch. Startup expected read-set pins
request journal and absent initial companion/opposite repair companion, alongside
existing approval/working/session/run records; updated initial companion joins the
same7-record startup cohort. Historical load pins exact retained run, referenced
terminal request, context and companion consistently. Recovery restores an optional
initial origin independently from repair reference; conflicting/corrupt origins grant
no inferred origin. Existing native22mode exercises repair only.

Next owned work: finish fixed supplied initial-request setup and distinct new-mode
report/read-set/failure matrix, including explicitly selected older identical return
versus later journal growth, actual retry pre-admission raw session, independent
cold validation of both companions and optional-corruption isolation. No new native
mode, app launch/kill, model/SDK command, copy/restore, stable replacement or
deployment delivered by this checkpoint. Keep this docs-only investigation claimed;
review/requiredCI/verified contract merge gate dependent implementation.


## Native initial-request lineage contract —20 November2026

Bounded F20/CE01/#404 investigation404-native-initial-lineage-investigation defines
one dependent implementation404-native-initial-lineage-fixture. This contract
delivers no runtime mode or new app-crash acceptance. Preserve actual native20/21
and repair22 readers/evidence; neither unbound candidates nor repair origins prove
initial request lineage. Native platform acceptance is only the owner's Mac, with
unavailable-platform work remaining under400. No live model or new SDK command is
needed for supplied metadata; loaded Qwen identity is not inferred from this fixture.

Two private native StudioDatabase probes pass, before/after actual startup commit.
Both begin with selected returned request1 and later returned request2 with identical
supplied changed-source results. Their request references remain distinct. At the
before pause all physical records equal baseline and no new context/companion is
durable, although the pending update map already contains encoded planned identity.
After commit exactly7 declared updates form the physical store delta; a fresh native
adapter joins request1, original formatted raw session, actual raw admission and
run1/context while latest returned request remains2. Startup result delivery stays0
and injected release failure leaves records unchanged. These are same-process
native database seam probes, not app kills, separate process reopen or source-copy
acceptance. Initial probe incorrectly passed response metadata to request reserve;
the production guard refused it. Corrected request-time model metadata passed; no
guard was changed. Probe/log:/tmp/asg404-native-initial-admission-probe_test.dart and
/tmp/asg404-native-initial-admission-probe2.log. Focused existing29 checks also pass.

Implement a separate fixed protocol23/mode initial-lineage. Challenge is EXACT6keys:
mode,nonce,launch,boundary,corruptOptional,sdk. Nonce lowercase32hex; launch1..4;
precommit only1/2, postcommit1..4; boolean corruption only postcommit read-only2
in a separate two-launch control (no retry). Canonical absolute existing SDK path
and private canonical nonce-bound fixture root use the existing safety limits;
challenge rawUTF8<=4096, reject duplicates/unknown/missing/invalid fields. Explicit
new-mode CLI flags reject legacy/task-decision/repair mode combinations before app
inspection/launch. No arbitrary command, database key, folder, script or stored PID
control. The new helper is not referenced by production main.

Setup: create one supplied approved Flutter fixture project restart-$nonce, session
session-$nonce with revision0/no dispatches, R1 and mapped Tanalyze (operation index3).
No failed baseline run or repair journal/origin is fabricated. Supply working and
prepared source folders explicitly with recorded source manifests; use ACTUAL
ApprovedSourceProposer twice with one deterministic injected provider returning the
SAME supplied source proposal, matching requested/observed model
supplied-native-initial-lineage-model and outputTokens4096. Request reservations
contain request-time model metadata; response identity belongs only to validated
returns. Preserve exact initialRequestOrigin from first result, then create second
return before baseline capture. Select first explicitly even though latest is2.
The selected reference is the existing5key v1 DTO: version,projectId,sessionId,
number,requestSha256. It hashes the canonical terminal metadata entry, never source
content or latest-request position. Both entries must be returnedValidated and the
actual first origin must pass production preparation/admission validation.

Initial journals retain returned FILE-HASH MAPS, not full proposal text. Therefore
report selectedReturnedSourceSha256/latestReturnedSourceSha256 are SHA256 of sorted
key canonical JSON maps of each entry's returnedSha256 and must match. Setup also
compares actual supplied proposal results directly while available. Those retained
map digests do not prove equal summary text or reconstruct a proposal. Selected and
latest terminal-entry hashes must be distinct, requestCount2, selectedNumber1 and
latestNumber2. No new request, provider return or budget consumption occurs on retry
or cold read. Request journal stays byte-identical after setup in this fixed case.

Launch1 target run1, dispatch candidate-restart-$nonce-1:3. Before commit, journal,
candidate, run1 execution/history/context/initial companion are absent and session
remains revision0. Postcommit startup has one admission/revision1 and all7 updates:
journal,candidate,session,execution1,history1,context1,companion1. Pause after actual
transaction BEFORE its future returns; caller/startup return, receipt preparation,
model transport, SDK and preview remain0. Host kills only its owned live handle
after the bounded report. Before-commit pause must not report captured bytes as
durable proof. Existing working bytes/request journal/unrelated records unchanged.

Launch2 independently reopens the exact native database through production readers.
Precommit remains absent/no dispatch; postcommit loads exact historical join for
selected request1 despite identical later return2. This is read-only: no host, source
inspection, proposal restoration/copy, verification, new record write or execution.
In separate corruption control only calculated run1 initial companion is replaced
with fixed opaque malformed bytes before reading; core session/run/history remains
available and stronger initial lineage unavailable. Report the deliberate mutation
separately; no fallback to request2, repair origin or raw hash-only proof.

Optional explicit retry launch3 uses production SavedCandidateRecoveryController
on run1, its original initial origin, actual current raw revision1 session and two
real working/candidate source inspections. New consent starts run2 with new context/
dispatch/companion and revision2 while retaining SAME selected request1 origin and
unchanged journal. Hold its actual seven-record startup return again. Candidate
record may be rewritten with identical bytes; count transaction members, not seven
necessarily changed hashes. Initial run1 audit/history/context/companion remain
byte-identical. Launch4 independently joins BOTH retained companions, validates
their exact reference1, original request raw bytes and distinct immediate admission
raw bytes/run/context/dispatch, and starts nothing. Legacy absent/conflicting or
malformed optional origins grant no inferred initial origin or additional authority.

Report23 has EXACT40keys (all hashes lowercase64hex or genuine absent null):
version, mode, nonce, launch, boundary, corruptOptional, stage, projectId, sessionId, boardTaskId, requirementId, requestedModel, observedModel, selectedRequestNumber, latestRequestNumber, requestCount, requestReference, selectedRequestSha256, latestRequestSha256, selectedReturnedSourceSha256, latestReturnedSourceSha256, targetRunNumber, targetDispatchId, committedTargetRunNumber, committedTargetDispatchId, proofState, originalRequestSessionSha256, capturedAdmissionSessionSha256, durableAdmissionSessionSha256, contextSha256, companionSha256, sessionRevision, sessionDispatchCount, recordsBefore, recordsAfter, unrelatedBeforeSha256, unrelatedAfterSha256, workingSourceSha256, preparedSourceSha256, counters.

Use fixed stage paused/read-only/retry-paused/retry-read-only. Target run1 for1/2,
run2 for3/4 is planned intent. committedTargetRunNumber/DispatchId stay null until
that exact durable run exists. proofState absent before commit, joined only after
full production join, unavailable only in the fixed corruption control. Never
conflate target IDs with a committed run or opaque hashes with a validated join.
Original request-session digest comes from exact selected metadata and, whenever
joined, decoded original raw companion session. Before-commit it must match actual
raw selected session; corruption may retain its independently pinned metadata/baseline
observation without claiming readable raw companion. CapturedAdmission hashes the
actual raw entry session at startup, pinned across launches; on retry it equals the
prior launch's actual retained session hash, never reconstructed typed JSON.
DurableAdmission is null for absent/unavailable proof and only hashes validated
stored admission bytes otherwise. Context/companion hashes are raw stored-slot
observations; opaque corrupt companion hash may be present with unavailable proof.

Fixed recordsBefore/After EXACT15aliases:
working, requestJournal, journal, candidate, session, execution1, history1, context1, companion1, execution2, history2, context2, companion2, repairCompanion1, repairCompanion2.

Map working to studio.generation.v1.$project, requestJournal to
studio.sessionProposalRequests.v1.$project.$session, journal/candidate/session to
current existing keys, executionN to studio.agentExecution.v1.candidate-$project-N,
historyN to studio.agentTaskHistory.v1.$project.N, contextN to
studio.candidateReopen.v1.$project.N, companionN to
studio.candidateRequestLineage.v1.$project.N, opposite repairCompanionN to
studio.candidateRepairLineage.v1.$project.N. Both opposite repair slots remain null.
New run slots absent before startup; run2 slots absent through launch2. Hash the
entire unrelated record map separately and pin it across launches. Cold record maps
equal preceding after maps; control corruption changes only companion1 after its
entry baseline. Source hashes are retained SETUP manifest metadata, not fresh cold
source inspections. Host physical-source inspections, if added, must be labelled
separately and cannot silently change those app counters.

Counters EXACT16keys:
setupProviderCalls, sourceSetupCalls, requestSetupCalls, hostCreations, recoverySourceInspections, startupCalls, startupRecordUpdates, startupReturns, hostEntries, receiptPreparations, liveModelTransportAttempts, sourceCopies, sdkAttempts, previewAttempts, unrelatedRecordWrites, corruptionControls.

Launch1 setupProviderCalls2,requestSetupCalls2,sourceSetupCalls1,hostCreations1;
launch3 hostCreations2/recoverySourceInspections2; cold host/inspection0. startupCalls1
only1/3; startupRecordUpdates7 only postcommit1/3. corruptionControls1 only control2.
All other counts0, including cold/startup-return/receipt/SDK/transport/copy/preview/
unrelated-record writes. Supplied source setup is not production copy and two
provider returns are not live inference. Report artifact writes are instrumentation,
not native record writes. Counters record actual boundaries, not success labels.

Existing8KiB report bound is the new-mode maximum too; demonstrate exact40key/15slot
report fits before accepting it. Raw root/challenge/report/baseline files stay bounded,
regular and canonical with existing no-symlink/private-root protections. Host pins
nonce, mode, launch, scenario, exact source and immutable compiled bundle identities
before/after every stage; validates each report before another launch. Only own
Popen handles may be killed/reaped; no owner-started processes or saved PID actions.
Retain final source/binary/report digests and refused/failed artifacts separately.
Do not reuse native observations for another binary/revision or relabel compilation.

Failure matrix: wrong modes/versions/identity/counter types, duplicates/unknowns,
nonfinite values, oversize/nonregular/symlink files, incompatible CLI flags; selected
reference swapped to latest despite equal returned maps, changed terminal metadata/
request journal/raw original/admission/context/run, foreign project/task/session/
dispatch/model, occupied initial/opposite repair slot, stale adapter and failed
transaction. No partial cohort or caller/host effects on refusal. Optional corrupt
first companion must fail independent dual-join even when newest remains valid;
core history control stays separately available. Historical proof must not suddenly
require current working approval/source or infer current execution permission.

Required implementation evidence: strict portable host/parser/mode and Dart input/
seam tests; actual owned Mac precommit2,postcommit/retry4 and corruption2 launches;
legacy20/21/repair22 regressions on SAME final binary, all bounded scopes labelled.
Then relevant full format/analyze/Flutter/productionweb/isolatedmacOS/product/inventory
checks, exact fresh PR review, both required CI jobs and verified protected merge.
Unchanged runtime evidence may be reused only under explicit policy; live/native
results remain exact-source/binary observations. No fullCE01/platform400/task
completion, model weights, source restoration, unrestricted execution or deployment
is established by this metadata fixture contract. If production seam cannot be
reached, keep native acceptance pending and fix the bounded fixture without weakening
production guards.


Implemented separate initial-lineage fixture23 now exercises explicit older selected
request1 after identical later request2 via actual supplied proposer, native atomic
startup/cold initial readers and production recovery retry. Both retained companions
are joined independently; optional corrupt data preserves bare history. Final owned
Mac23cases8launches plus preserved22/21/20cases18launches pass on bundle
1a659b72cbb6eb0fb3a5b80103c68821744ba375e0cf6de70727d70b695b4d7d.
This is supplied metadata/source fixture evidence, not production source-copy, live
inference, general SDK or fullCE01/platform acceptance. See canonical requirements/
progress for source/report digests and exact validation limits.


## Live initial-request prerequisites —20 November2026



Live initial-request prerequisite checkpoint at2026-11-20T01:50:07Z. Both local
8765 /health and /v1/models fail with URLError/ConnectionRefusedError errno61.
/tmp/asg404-live-initial-runtime-{preflight,recheck}.json. No model identity, MLX/
Metal readiness or response model can be established; generationAttempts0. Do not
substitute models or relabel supplied native23 evidence as live. Exact missing
prerequisite: existing owner runtime must become reachable at8765, health ready
onMLX/Metal and models advertise exactQwen3.8-27B-4bit before a bounded live request;
actual matching response ID is additionally needed before any passing live claim.
No server/model process was started/stopped/changed, installed or downloaded. Root's
read-only runtime checks settled with no active request; another runtime worker
must still be explicitly assigned before any later live inference.

Useful local prerequisite completed despite unavailable runtime:2private synthetic
loopbackHTTP-to-native-journal integration probes pass using ACTUAL default
LocalModelProvider through SourceEditProposer/ApprovedSourceProposer and physical
StudioDatabase records. This server is a supplied SSE fixture on a disposable
loopbackport with neutral synthetic-http-initial-metadata identity, not8765, not
Qwen or live inference. At HTTP arrival the physical native journal already has
reserved intent with no response identity. Matching supplied response yields exact
validated-return metadata/original raw initial origin; mismatched response yields
failedLocally with no validated origin/returned hashes. Actual DB close/reopen
retains exact outcomes and raw records; one HTTP request per case, no replay.
Only request journal changes; working/session/all unrelated records unchanged,
candidate journal absent. Fixture server/client/database are closed and private
files removed; no source application/copy/SDK/preview/candidate admission occurs.

Probe:/tmp/asg404-initial-http-journal-probe_test.dart; final strengthened log
/tmp/asg404-initial-http-journal-probe3.log (2PASS, including physical reserved
record assertion). Earlier mismatch assertion was tightened to FormatException/
StateError so timeout cannot count as expected refusal. Component proposer/journal/
source/transport42PASS:/tmp/asg404-live-initial-prerequisite-tests.log. These are
2synthetic integration probes plus42component checks, never44live observations.

Concrete next owned work: finish bounded live-verification prerequisites/opt-in
validation plan and determine whether these composed HTTP/native-journal cases
need permanent regression coverage (existing tests isolate supplied provider from
transport). Current task stays docs-only/in progress, live acceptance pending.
Exact review/requiredCI/verifiedmerge still gate bounded investigation completion.
No production source changed, no cloud/native app/stable replacement/deployment.
FullF20/CE01/umbrella404 and unavailable400 stay open; preserve owner processes
and last working outputs, resume this owned investigation first.


## Initial-request transport/journal prerequisite result —20 November2026

Bounded investigation404-live-initial-request-investigation is locally complete
as a prerequisite result; current live inference acceptance remains pending. It
found one concrete integration-coverage gap: selected initial-request tests inject
a supplied provider, while local transport tests inject HTTP clients. Neither
existing suite composes ACTUAL default HTTP provider, selected-session proposer and
physical native journal across reserve/response/outcome/reopen. Private synthetic
loopback/native probes now demonstrate that composition without a running model.

New third probe passes: native reservation persistence refusal prevents ANY HTTP
request and leaves the entire physical records map unchanged. Fault wrapper rejects
only initial request-reservation commit before delegation; it does not fake a
transport failure after sending. Probe:/tmp/asg404-initial-http-reserve-refusal-
probe_test.dart, log same-prefix.log. Together with matching-response/mismatched-ID
probes in /tmp/asg404-initial-http-journal-probe3.log, there are3synthetic composed
observations plus42existing component tests, not45live model runs. The synthetic
server is always separate from8765, neutral fixture model ID, and has no weights.
Only its owned endpoint/client/database are opened/closed; source is never applied.

Next bounded dependency-ready implementation AFTER this contract's verified merge:
404-initial-http-journal-regressions under SAME#404. Add one permanent focused test
file test/initial_request_http_journal_test.dart with three portable VM cases:
1. At actual HTTP request arrival, direct physical native record already shows
   reserved initial intent with no response model. Successful bounded SSE under
   matching neutral fixture ID produces returnedValidated, matching observed ID,
   exact initial request reference/raw session and only declared returned-file hashes.
   Close/reopen actual database; exact journal/outcome survives with no HTTP replay.
2. Supplied different response model ID must fail production transport/proposer
   validation, retain failedLocally with no validated return/origin/returned hashes,
   and preserve working/session/all unrelated records through native close/reopen.
   Timeouts cannot count as expected mismatch; assert actual allowed refusal types.
3. Refused durable reservation produces0HTTPcalls, no journal/partial records, no
   observed response, and no file/candidate/SDK/preview effects. Do not introduce a
   fallback provider or swallow errors to turn a failure into a validated return.

Use default ApprovedSourceProposer->SourceEditProposer->LocalModelProvider against
a private loopback HttpServer on an ephemeral port, not an injected model provider
or a mocked HTTP client. Seed only synthetic approved task/session/working metadata
in disposable native database; do not touch owner application storage. Request
source max_tokens stays4096. The fixture sends fixed small SSE; body/model/path/
stream/token assertions prove the composed API contract, not model correctness.
Restore HTTP overrides and close owned service/server/database/temp files on every
path, including setup failure; bound waits and surface callback failures. Native
DB adapter must actually close/reopen rather than merely reload a typed object.
Tests should run on existing Mac and Linux VM CI without platform skips, native
apps, live model, SDK invocation, installation or new dependency. Preserve strict
source parser, response-model validation, request budget/consent/Stop/error behavior
and current wire formats. No production runtime change is planned for this gap.

Follow-up owned scope: that test, REQUIREMENTS/PROGRESS and acceptance inventory as
needed; shared integration owner handles ledgers. One coherent writer is sufficient.
Acceptance needs3composed cases PASS, relevant existing42tests, architecture, full
format/analyze/Flutter and requiredCI including browser/web checks; source inventory
regenerated only if relevant inputs change, with historical observations unchanged.
No test mirrors an implementation method; each verifies an external HTTP/durable
ordering or failure boundary. Fresh exact PR review and verified protected merge
are mandatory before recording this regression increment delivered.

Future LIVE opt-in validation is separate and NOT satisfied by these tests:
- Check existing8765health ready with actualMLX/Metal and /v1/models exact
  Qwen3.8-27B-4bit. Verify current server budget permits sourceOutputTokens4096 and
  serialized availability; do not lower or bypass production ceilings to force it.
- Assign exactly one runtime worker, leave owner-started processes alone and avoid
  competing requests. Inability to prove readiness/identity/budget keeps it pending.
- Use one small synthetic approved initial source request via actual production
  proposer/default transport to that exact configured endpoint/model. No candidate
  admission, file copy/application, SDK or preview; original working/session stay.
- Actual successful stream response must expose non-null model ID EXACTLY matching
  Qwen3.8-27B-4bit before passing live metadata proof. A requested ID or advertised
  model alone is insufficient. Server assertion still is not authenticated weights.
- Verify physical reserve-before-transport, returnedValidated/reference/raw original
  session/returned hashes and actual native close/reopen with no replay. Invalid
  JSON, truncation, mismatch or persistence failure remain failure/unknown evidence,
  not a reason to retry automatically or claim the server stopped inference.
- Record tested revision, date, health/backend/device/model/request limits and actual
  matching response identity; retain private raw responses separately. Never commit
  prompts, source bodies, credentials or private model/endpoint payloads.

Both8765endpoints currently refuse connection(errno61), so no live generation was
attempted and no live model observation exists. Existing runtime must become
reachable with the documented ready identity/budget before that acceptance becomes
eligible. Continue the portable regression increment; no model/process install,
download/start/stop or cloud/stable-app action is authorized by this contract.
FullF20/CE01/umbrella404 and unavailable400 remain open.

## Native unresolved initial intent contract — 20 November 2026

This is the execution boundary for the next bounded #404/CE01 fixture, not a new
queue. REQUIREMENTS.md owns selection/completion. Existing protocol23 begins after
two validated supplied proposals; it cannot prove an app-process interruption at
initial reservation. The current private HTTP/nativeDB probe and 85 component
checks establish a narrower prerequisite only. No process-crash acceptance is yet
claimed. Keep live Qwen, general CE01/F20 and deferred platform400 acceptance open.

### Fixed mode, storage and launch sequence

Use a separate protocol24 mode `initial-unresolved`, challenge at most4096 UTF-8
bytes with EXACT keys `mode, nonce, launch, sdk, explicitNext`. Reject duplicate or
unknown keys, wrong types (bool is not int), mode/version mixing, invalid32lowerhex
nonce, noncanonical/unsafe SDK paths and unsupported stage combinations. SDK is the
existing common driver input, inspected but NEVER executed by this mode. Launch1/2
require explicitNext=false; launch3/4 require explicitNext=true. Default driver
`--initial-unresolved` has two launches. Explicit `--unresolved-next` adds launch3/4;
other scenario, nondefault operation, repair/initial-lineage, retry, corruption or
stop selections must fail before bundle launch. --unresolved-next without the primary
mode must also fail before launch. Do not change legacy20–23 behavior or guards.

Parent fixture still requires the existing opt-in isolated bundle, private0700
canonical disposable root under system temp, bounded regular nonsymlink challenge,
fresh nonce-specific native database and preference prefix. Preserve original
records and schema/wire formats. Only launch1 seeds a tiny synthetic approved board,
plan, selected session and working-build metadata, with in-memory source hashes.
No source tree/file copy, candidate, execution host, SDK or preview is needed.

| Launch | Stage | Fixed observable boundary |
| --- | --- | --- |
| 1 | reserved-paused | Invoke real ApprovedSourceProposer with a supplied provider factory, intercept its initial reservation commit, delegate to real native storage, verify physical reserved intent and report, then hold commit completion indefinitely. Provider factory/generate never enters. Parent validates report, proves owned child is still live and kills/waits its exact subprocess handle. |
| 2 | read-only | Separate launch opens the same native DB and only reads. Request1 remains reserved with no observed model/returned hashes. Complete raw record map and unrelated digest equal launch1 after. Report then exit0; no request, new approval, candidate, replay or inferred remote outcome. |
| 3 | fresh-return-paused | Optional explicitly selected fixture continuation, never a reopen default. Read and preserve unresolved1, obtain current saved approval/session binding and call the real proposer afresh with one fixed supplied response. Durable reserve2/validated return2 and actual returned origin2 must complete. No candidate admission. Report and hold; parent kills only this owned live child. |
| 4 | fresh-read-only | Separate read-only launch retains EXACT unresolved1 and distinct returnedValidated2/reference2. No provider, new proposal, mutation, source restoration or execution. Report and exit0. |

Withheld reservation completion is the key first boundary. A pause after a model
response, a manually invented reserved record or a process that already exited
cannot satisfy launch1. Cold reads must not resolve unknown request1 by assumption.
Any terminal result is request2 only, from a fresh explicit action and unchanged
current consent; origin2 must not match1. A supplied model identity is test metadata,
not a live bridge or authenticated weights. No HTTP transport/model process is used.
VM pause injection may release by throwing after report for deterministic tests,
but must be labelled same-process evidence; only parent-owned native kill/relaunch
observations establish process acceptance. Do not signal unrelated PIDs or stable app.

### Strict report identity and cohort

Report maximum8192 UTF-8 bytes, EXACT32 fields:
`version, mode, nonce, launch, explicitNext, stage, projectId, sessionId, boardTaskId,
requirementId, requestedModel, requestCount, unresolvedRequestNumber,
latestRequestNumber, unresolvedRequestStatus, latestRequestStatus,
unresolvedRequestSha256, latestRequestSha256, unresolvedResponseModel,
latestResponseModel, unresolvedReturnedSourceSha256, latestReturnedSourceSha256,
originalSessionSha256, sessionRevision, sessionDispatchCount, requestReference,
recordsBefore, recordsAfter, unrelatedBeforeSha256, unrelatedAfterSha256,
declaredSourceSha256, counters`.

version is exactly24; mode exactlyinitial-unresolved; requestedModel exactly
`supplied-native-initial-unresolved-model`. projectId=`restart-<nonce>`,
sessionId=`session-<nonce>`, boardTaskId=Tanalyze, requirementId=R1. Request1 is
ALWAYS number1/reserved, null observed model/null returned-map digest. Latest is
1/reserved on launches1/2, 2/returnedValidated on3/4, with exact supplied observed
model and nonnull returned-map digest only on3/4. Request count is1 or2 respectively.
Hashes are lowercase64hex of exact retained wire or explicitly canonicalized typed
request/returned-source maps, never source text. Request digests use the production
UTF-8 jsonEncode(request.toJson()) member order, as SessionProposalRequestReference
uses; do NOT sort those members or construct a returned-only reference for reserved1.
Map digests use UTF-8 jsonEncode with entries sorted by key, matching existing
native fixture _mapHash. Slot digests hash the exact raw stored string instead.
Python validates schema/transitions and digest links, not cryptographic provenance. requestReference is null on1/2; on3/4 it has exactly
`version, projectId, sessionId, number, requestSha256`, version1/number2 and the
latest request digest, with current production reference construction/validation.
Its presence on a cold read is historical metadata, not a restored proposal/permit.
originalSessionSha256 equals request1's captured raw-session fingerprint and the
unchanged session record hash. Session revision0 and dispatch count0 throughout.
declaredSourceSha256 is a digest of seeded source-hash metadata, NOT a fingerprint
of existing filesystem source or a verified application/build output.

recordsBefore/After have EXACT10 slots:
`working, requestJournal, session, candidateJournal, candidate, execution, history,
context, initialCompanion, repairCompanion`.
The exact nonce-bound slot mapping, with p=projectId and s=sessionId, is:

| Slot | Production key |
| --- | --- |
| working | studio.generation.v1.p |
| requestJournal | studio.sessionProposalRequests.v1.p.s |
| session | studio.agentSession.v1.p.s |
| candidateJournal | studio.candidateChecks.v1.p |
| candidate | studio.sourceCandidate.v1.p |
| execution | studio.agentExecution.v1.candidate-p-1 |
| history | studio.agentTaskHistory.v1.p.1 |
| context | studio.candidateReopen.v1.p.1 |
| initialCompanion | studio.candidateRequestLineage.v1.p.1 |
| repairCompanion | studio.candidateRepairLineage.v1.p.1 |

Substitute p/s literally, never the letters in the table. Map each key once and
test against current model constants. Never invent a new production key or treat
an absent wrong-key lookup as proof. Every
present slot is the SHA256 of its RAW stored string; absent slots are null.
Working/session are present and immutable. requestJournal absent before launch1's
reserve, present after; it may change only for fresh request2 on launch3. Other7
slots stay null. Hash all remaining native records independently as unrelated;
their digest must never change across before/after or launches. Read-only2/4 have
identical before/after maps. Before2 equals after1; before3 equals after2; before4
equals after3. Immutable request1/session/declared-source fingerprints never change;
request2 digest differs from1 even when source is identical. Reject missing cohorts,
unexpected records, changed unrelated/working/session, request aliasing or stale
nonce/project/session/stage/reference.

EXACT14 integer (never bool) counters:
`setupCalls, proposalCalls, reservationCommits, reservationReturns,
suppliedProviderCalls, proposalReturns, terminalCommits, liveTransportAttempts,
sdkAttempts, candidateEffects, unrelatedWrites, previewAttempts, sourceCopies,
hostCreations`.
Launch1 has setupCalls/proposalCalls/reservationCommits=1, all others0.
Launch3 has proposalCalls/reservationCommits/reservationReturns/suppliedProviderCalls/
proposalReturns/terminalCommits=1, all others0. Cold2/4 all0. Instrument actual
entries/commits rather than prefill successful counters; reject writes outside the
single request-journal cohort after seeding. Cold stages use rejecting mutation
wrappers and compare physical DB maps, including around migration/open. Count and
refuse any attempted live/model/host/copy/SDK/preview effect. No receipt authority or
new execution permission is added by this fixture.

Native host must validate bounded strict UTF-8 JSON (duplicate/unknown members and
bool-int confusion rejected), report nonce/schema/stage/full cohorts and every
cross-launch transition BEFORE accepting an observation. Inspect immutable bundle
identity/executable digest before each launch and before each owned kill; missing,
partial, wrong-stage report, premature exit, wrong signal/result, symlink roots or
report replacement fail closed. Deadlines and cleanup apply to owned processes,
with finally kill/wait only if that exact subprocess is still live. No build,
install, model download, runtime startup or stable app replacement in the driver.
Preserve public report scope: local observations, not authenticated remote state.

### Implementation and validation boundary

After this investigation's verified merge, use SAME#404 task
404-native-unresolved-initial-fixture. Root owns new
`tools/fixtures/native_initial_unresolved.dart`, parent Dart routing,
`test/native_initial_unresolved_fixture_test.dart`, REQUIREMENTS/PROGRESS/
AGENT_ENGINE/inventory. A second independent host writer may own new
`tools/native_initial_unresolved.py`, Python driver routing and host regression
file, once both register separate nonoverlapping worktrees/claims against this
merged contract. Agree on the literal key mapping, schema above and test fixtures
first; serialize shared integration/build resources. No writer edits another scope.
Stop clean handoffs before integration-owner union claim if scope changes.

Validation: fixed challenge/report/transition refusal tests on Dart/Python, VM
same-process stage2/4 no-write tests and fresh-request1/2 identity checks, current
journal/controller85 regressions and private composed probe. Run format/analyze/
fullFlutter/product/inventory and existing requiredCI. Build one isolated fixture
binary from exact final source, record source/executable digests; run new2-launch
and explicit4-launch cases with separate private nonces (6 launches total), then
relevant legacy23/22/21/20 acceptance on that SAME binary with original supplied/
SDK receipt scopes. Preserve historical evidence. Native tests cannot be replaced
by a VM throw or by old-binary reports; host report validation cannot alone prove
a subprocess was killed. Fix/retest/review final inputs and verify protected merge
before declaring this bounded fixture delivered. FullCE01/F20/liveQwen/unavailable
platform acceptance remain pending. Existing approvals, Stop/recovery and last
working outputs are unchanged.


Protocol24 implementation checkpoint: Dart reservation hold/read-only/fresh-return
stages and fixed routing are implemented, with10VM tests and115focused regressions
passing. Four actual VM reports also satisfy the separate host validator. Native
process acceptance remains pending final integrated isolated binary/owned launches.
VM pause release, strict report validation and a build alone are not crash proof.


Protocol24 actual isolated Mac acceptance checkpoint: primary2 and explicit4
launches pass, plus preserved legacy23/22/21/20 twenty-six launches on SAME bundle
f5cb4d4d9fa42b68b58318568a03465d6bc676dd3562875c2304a9d301da249a.
Reserved1 remains unresolved across owned crash/cold read; explicit validated2
preserves1 and no reopen replay occurs. Newcases have no provider before first
pause, no live model/SDK/copy/candidate/host/preview. Legacy20 retains its original
fixed SDK/receipt scope. 603source inputs
edef48dfdcb3be700c1d100f0a2b8dc6d19fb113a7992ea336a0487a23d0752f stayed
unchanged after all32launches; sourcecommitf019cb4 and private source/evidence
summary in /tmp/asg404-native-unresolved-*.json identify actual tested inputs.
Full2228/12opt-in skips, focused115/host118/restart6 and analysis/format pass.
Final exact review/requiredCI/verifiedmerge remain gates; no generalCE01/F20,
liveQwen or unavailable-platform acceptance claimed.


PR774 fresh-review hardening: revised driver refuses unsafe challenge/log files
before launch, pins atomic challenge replacement and uses exclusive no-follow logs.
121host/6restart tests pass, including original-driver failing symlink regressions.
All32same-binary native observations repeated with driverbc8dbaa/digest
feaa8a1898e151d54d1c67f441b3b63864f46e7238ff30349af2be3b7a0af3f5.
Native603source inputs/bundle remain unchanged; original driver evidence is kept
separately. Final revised review/requiredCI/verifiedmerge still gate delivery.


Final VM portability correction keeps the private-root guard strict: own scratch
roots explicitly0700, exact pause errors required, Linux enabled. Full2229/12skips
and116focused pass. A separate final build/source51c3ba4/603inputs832e6f690016adcaaed4eda3ad1bdeb085f5d2147808f3c20f54e76709651782
produced bundlee6ed3a85de0c7b847958c2aa38c5b9448a8643c5db6bd914fc2e076219013bfd;
all32native cases repeated successfully on it, prior bundles/reports preserved.
/tmp/asg404-native-unresolved-posix-evidence-summary.json records exact source/
driver/bundle/report identities. Final revised review/requiredCI/verifiedmerge
remain gates; failed earlier CI does not authorize delivery or platform claims.


### 2026-11-20 — #404 initial return boundary investigation started

PR #774 verified merged at d083f8502d0c652f7442e432839575409207242b,
exact tree 9f6c83b08c0e5a9667e099feac23a6a359caa693. Fresh review covered
remote head a641e36860c45800a9badeef7281e26cc1bee1af; required CI run
44672150217 passed both jobs and every required step. Eleven new VM tests
ran on Linux. Final isolated Mac bundle passed all 32 native observations.
Coordinator merge/outcome recorded; integration lock and previous claim released.
#404 remains open for unmet F20/CE01 acceptance, including live inference.

Next eligible bounded task: 404-initial-return-boundary-investigation under #404,
claimed by the integration owner in its registered issue worktree. Scope is this
ledger, PROGRESS.md and AGENT_ENGINE.md only. Acceptance: trace terminal write
ordering, independently hold before and after physical terminal commit using
actual synthetic loopback HTTP/native records, verify no early result, truthful
stored status, final origin/hashes and unchanged unrelated records after actual
close/reopen, and identify a bounded native-process follow-up. Root is the sole
assigned runtime worker; no second independent ready writer is admitted.

At 2026-11-20T04:19:50Z, fixed 8765 /health and /v1/models both refused
connection (curl exit 7, HTTP000); generation requests zero. Existing owner model
was neither started nor replaced. Exact Qwen3.8-27B-4bit live acceptance remains
pending until the existing MLX/Metal endpoint is ready and identity verified.

Private prerequisite probe /tmp/asg404-return-boundary-probe.dart passed 2/2
using existing default HTTP proposer, supplied synthetic model metadata, and a
disposable native database. Before physical terminal commit the journal remained
reserved; after commit but before its Future completed it was returnedValidated.
Both holds prevented proposal delivery. After release, request 1 had the exact
validated origin and nonempty returned hashes; unrelated/session/working records
were byte-equivalent. Actual database close/reopen retained the final raw map and
one HTTP call, without replay. Cleanup settled pending work and removed temporary
records. Log: /tmp/asg404-return-boundary-probe.log. This is phase-boundary evidence,
not process-crash or live model evidence. Production ordering sets the terminal
attempt flag before commit and exposes returned origin only after awaiting commit.

Next bounded implementation candidate is native-process verification at these two
terminal outcome boundaries, with parent-owned kill/wait, independent cold read,
no automatic replay, preserved unrelated records and exact distinct references.
Its report/host contract still needs investigation and review before implementing;
current docs-only investigation remains active. Marketplace dependencies, F23-last
and unavailable-platform acceptance under #400 are unchanged. No installs,
downloads, source execution, stable app replacement, provisioning or deployment.

### #404 native initial terminal-return boundary contract (investigated, not implemented)

Evidence gap: protocol24 launch1 holds reservation completion BEFORE any provider;
launch3 holds only AFTER ApprovedSourceProposer has fully returned. Neither kills
an actual native process between a supplied validated response and completion of
the terminal journal write. The two private HTTP/native probes above exercise
that interval but do not establish crash durability. Do not relabel them as such.

Next eligible implementation, dependent on this investigation's verified merge:
`404-native-initial-return-boundary`, under existing #404. Preserve modes20–24;
new isolated protocol25 mode `initial-return-boundary`, no production app flow or
storage schema changes. Challenge exact keys: mode, nonce, launch, sdk, boundary.
Boundary enum beforeCommit/afterCommit, launch integer1/2 only, nonce32lowerhex,
fixed SDK inspection only. Challenge <=4096bytes and report <=8192bytes; refuse
unknown/duplicate keys, nonfinite values, booleans as integers, malformed/mixed
flags, stale reports and wrong identities before any child/record side effect.

Each boundary is a separate fresh private0700 root, fixed supplied provider model
`supplied-native-initial-return-boundary-model`, one fixed request1, no HTTP/live
transport. Launch1 physically commits the reservation and returns to provider;
provider emits fixed validated source once. Wrapper validates exact expected keys,
owned journal state and no other writes. beforeCommit holds BEFORE delegating the
terminal commit; afterCommit delegates, verifies physical bytes, then holds BEFORE
its Future resolves. Report only after held state is reached. Proposal Future must
remain pending; no returned-origin getter/reference may be reported as delivered.

Stage1 counters: setup1/proposal1/reservationCommits1/reservationReturns1/provider1,
terminalAttempts1/proposalReturns0, terminalCommits0 before or1 after; every live,
SDK, candidate, preview, copy, host and unrelated-write count0. Separate validated
response identity/hash fields describe fixed supplied metadata, never live weights.
Physical request1 remains reserved with null stored response/hashes beforeCommit;
afterCommit it is returnedValidated with exact supplied model and source hashes.
Store fingerprint, returned hash and proposal delivery are distinct observations.

Parent pins bundle/source/root/challenge/report identities and only its Popen
handle. Validate report, confirm same child still alive at the hold, kill/wait
expected -9, then launch2 as a separate cold read-only process using same root and
fresh exact nonce-bound challenge. Cold counters all0 including provider/proposal,
no replay/commit/copy/SDK/preview. Reopen native database, compare exact journal,
original raw session/working/unrelated map against bounded private capture;
requestCount1 and the same physical status/model/hashes must persist. Cold may
derive a retained validated record reference only in afterCommit, labelled durable
record identity; it is not evidence that launch1 delivered a proposal. beforeCommit
must have no returned-only reference. Both processes must refuse altered journal,
foreign/nonmatching capture and request identity; never repair corrupt records.

Report schema implementation must explicitly enumerate identity/stage/boundary,
request status/fingerprints, physical response/hashes, deliveredReference=null,
optional cold retainedReference, exact ten literal record slots, unrelated hashes
and exact counters. No arbitrary journal keys, paths or source text in reports.
No fresh-request continuation or candidate dispatch is needed for this bounded
outcome. Those effects remain separately gated by existing approval policies.

Validation: permanent focused Dart tests for strict parser, both gate phases,
no early delivery and real close/reopen; portable Python host tests for both
sequences and adversarial report/control-file inputs including symlinks; active
Linux POSIX VM coverage with fresh private roots and precise expected errors.
Then format/analyze/full Flutter tests/web build and Python required checks on
final revision. Build a NEW isolated macOS restartfixture bundle, identify all
source inputs and whole bundle hash, and observe4actual launches (2per boundary).
Repeat preserved20–24 matrix on the SAME new bundle, keeping metadata distinct
from existing dated bundles. Kill/wait owned children and verify cleanup before
releasing resources. Never replace stable app or start/stop owner runtime.

Investigation evidence: private probe SHA256
 e23ca597fae22cc55170b8b2428f18948e928450e1f6382ca008ed56c44d94a2.
Two actual synthetic HTTP/native DB probes PASS; native protocol25 and native
crash observations remain PENDING. Full F20/CE01, live Qwen and #400 remain open.

Investigation verification: 25 focused Flutter checks PASS (including both private
HTTP/native terminal gates), product acceptance32 PASS, inventory9 PASS; diff
whitespace clean. No application code changed. Protected final-revision CI and
fresh PR review remain required before this contract is marked delivered.


### 2026-11-20 — #404 terminal-return investigation merged; native track started

PR775 protected merge1d645ce865d4c3fd33b170a8a652bbb1b3b279fc verified through
GitHub main, merged PR and fetched tree392a6a3f1defac9c69c03fdd3ba5a41006a93054.
Fresh review remote b99190ca58999a8460ca231cff2e7f4b8dc2d084/base d083f85
found no blocking issues; conversations empty. CI44674096322 Python136081679354
and Flutter136081679148 both SUCCESS, every required/post step passed. Local
format556 unchanged, analyze clean, full2229PASS/12explicit skips, web built;
focused25/product32/inventory9 PASS. Coordinator merge/outcome recorded and
integration/claim released. Full #404 remains open.

Immediately claimed dependency-ready task404-native-initial-return-fixture in
registered issue worktree; root owns Dart fixture/test/router, shared docs/inventory,
and sole isolated native build resource. Strict bounded protocol25 challenge parser
and permanent adverse tests started; two tests PASS (four valid phase/launch
combinations plus malformed/foreign/mixed/oversized cases). Runtime/host integration
and actual native observations remain pending. Host-only disjoint writer tasked
404-native-initial-return-host with Python module/router/regressions; it must claim
before edits, no native build or live runtime work, handoff stopped and serialize
publication through root. Exact report design30fields/10slots/16counters, four
placeholder samples max2589bytes, private designSHA256
4984ddcd000f2bddef11fcb213747512d6a239dd03669ccb3133fec03e2a2d8b.
These samples are design only. Existing model readiness observation remains
connection-refused; zero inference, no owner process changed or stable app replaced.


#404 native initial terminal fixture handoff: protocol25 fixed supplied provider
now holds before/after physical terminal commit; both reports distinguish stored
response, supplied validated metadata, delivered=null and cold retained reference.
Actual native DB VM phase/cold read, corrupt journal, foreign capture and symlink/
privacy refusal tests PASS; focused47PASS, Flutter and explicit fixture analysis
clean. Native app crash proof still pending. Host disjoint handoffc4d97134 verified
clean/stopped,134portablehost+6restartPASS, no process/build/inference observations
claimed. Root will acquire union ownership before integration and new isolated
Mac build. Owner runtime/stable app/last output/other edits preserved.


### #404 native initial terminal boundary final local evidence

Integrated clean stopped/released handoffs f6294c90502c16bc5a0d69bbc832079a404d71dc
and c4d97134c3a8c6e47ec500a047474139c94ef791 only after acquiring exclusive union
claim404-native-initial-return-integration; sourcecommit853054f85eedfa2034bb6a233e81aaffbd0fe0b5.
Protocol25 exact30reportfields/10recordslots/16counters, five-key bounded challenge.
Supplied provider metadata only, no live transport. Before terminal commit report
has validated metadata but physical reserved/null stored response; after physical
commit report has returnedValidated/exact supplied model+hashes. Both have pending
proposal, terminalReturns0 and deliveredReference=null. Parent validated same live
owned child, killed/waited -9, then separately cold-opened read-only. Before stays
reserved with no reference; after retains exact validated record reference labelled
retained only. Both cold reports have all counters0, no provider/replay/proposal,
unchanged raw journal/session/working/unrelated records. No source restored.

NEW isolated bundle:
/private/tmp/asg404-native-initial-return-derived/Build/Products/Debug/Automated Software Generator.app
Identity com.arsinha.asg.restartfixture, explicitly launched only; stable app and
all older working bundles preserved. Whole-bundleSHA256
198761d8fd1124a57679b92aa27c9b84d6e69562969d541f9a44d34e99acb542.
605 pinned source inputSHA256
07b8cd979f4bd9ae4fdf86501ff6b83f0d60703d9a52bd4948d50bdc5d81a385.
Three Python host-inputSHA256 e4f30993363105a5d0767292d4c1c56b1e5c8ea4f37a8da82b5efc7c4197e63c.
All inputs byte-identical after all36actual native launches on this SAME bundle:
new protocol25 before2+after2=4; preserved24 basic2+explicitnext4=6, protocol23
precommit2/retry4/corrupt2=8, protocol22 equivalent8, decision21five, legacy20five
bound running-stop/ack/retry/promotion. New mode does not run SDK/model/preview/
candidate/copy/host; legacy20 retains its original fixed SDK/receipt scope. Owned
fixture processes settled. No owner-started process stopped. Source/bundle/case
receipts: /tmp/asg404-native-initial-return-{source-manifest,bundle,evidence-summary}.json
and twelve separately hashed reports named in summary; no earlier evidence relabelled.

Local final validation:47focused Flutter PASS,8newVM/parser/adverse tests PASS,
format559 unchanged; Flutter analyze and explicit fixture analysis clean; full
Flutter2237PASS/12explicit live skips, web built. Python134host+6restart+32product+
9inventory PASS. Inventory regenerated unchanged. Style/import issues fixed before
final validation; no escaped defect observed. Fresh exact PR review and ALL required
CI remain mandatory. This bounded native outcome does not complete fullCE01/F20/
#404/liveQwen/#400; marketplace dependencies/F23-last unchanged. No installs,
model downloads, unrestricted execution, stable replacement, cloud or deployment.


### 2026-11-20 — #404 native terminal return merged; repair investigation started

PR776 protected expected-head merge d53e0b0a31b4e52d2dbb0c968e0fb40f52e03538
verified through GitHub main, merged PR and fetched exacttree
86f19fd0b8854cb543afc3a66ee44170c753e54a. Fresh review remote
0edd6bbdbdb177da0a386e79cc123651736f7eb1/base1d645ce8 found no blocker;
threads empty. Required CI44676740892 Python136090257325 and Flutter136090257659
every mandatory/post step SUCCESS. Linux logs confirm all8newDart cases active
PASS. Native36launches and full2237/12skip local evidence retain their exact bundle/
source identities above. Coordinator merge/outcome recorded; integration and claim
released. Owner checkout's separate IDE/history edits preserved; umbrella404 OPEN.

Immediately claimed next dependency-ready bounded task
404-repair-return-boundary-investigation under existing #404, registered direct
issue worktree. Scope this ledger, PROGRESS and AGENT_ENGINE only. Acceptance:
trace repair terminal write versus returnedReference, verify two actual disposable
nativeDB component gates and cold reopen with exact selected origin/failure/session/
working/unrelated maps, check current fixed runtime readiness, then define bounded
next native contract only if supported. No second independent ready writer; root
is sole readiness/runtime worker; no live inference or app build assigned.

Concrete gap: RepairAttemptStore.finish sets _outcomeWriteAttempted before _commit,
awaits proposed repair persistence, then exposes _returnedReference. Native repair
protocol22 seeds by awaiting the full ApprovedSourceProposer return before later
candidate boundaries, so it does not cover this earlier terminal-write interval.
Private /tmp/asg404-repair-return-probe.dart now passes2/2 component observations:
before physical commit status reserved/no proposal; after physical commit status
proposed/stored proposal. Both holds keep returnedReference null and original
finish Future incomplete. Release yields exact matching selected reference; actual
database close/reopen retains full map and selected origin byte-identically, with
no replay/provider/transport or source application. Original failure/session/working
and every other record remain unchanged. Initial harness attempt correctly refused
a context bound to a different storage wrapper; binding context and store to the
same guard corrected the probe, without application changes. This is component
evidence, NOT actual native process crash, HTTP or live model evidence. ProbeSHA256
637dd2b84aa6d46257b01045e3cb2eb27dddb9b05fe53a5e3fa8b09fe3bb6892; log /tmp/asg404-repair-return-probe.log.

At2026-11-20T04:56:05Z fixed8765 /health and /v1/models both refused connection
(curl7/HTTP000); generation requests0. Existing server not started/stopped/replaced.
Live Qwen3.8-27B-4bit acceptance remains pending exact ready MLX/Metal endpoint.
Next work: specify the selected repair origin/journal report and two native terminal
gates, with exact retained failure and no delivered/proposal-execution claim,
then review this investigation before admitting implementation. FullF20/CE01/#400,
marketplace gate and F23-last unchanged; no installs/downloads/cloud/deployment.


### #404 repair terminal-return boundary investigation and next contract

Final prerequisite evidence:44focused Flutter checks PASS, including four private
nativeDB components (before/after physical terminal commit and two physical
conditional-commit races). The latter bypassed normal application storage only
inside disposable DB records: noncanonical selected origin and malformed physical
repair journal were both retained byte-identically after proposed-outcome refusal;
returnedReference stayed null and outcomeWriteAttempted true. Normal storage API
correctly refused malformed writes during harness setup; no application defect or
fix inferred. Final private probeSHA256 dddab5b8059a7c14f7b5cb3a879cbe72641001fe8931d3fb5dd14077b09b2cd8.
Log /tmp/asg404-repair-return-focused.log. Component probes do not invoke provider,
HTTP, native app process or live model and establish no crash/device acceptance.
At2026-11-20T04:59:08Z /health and /v1/models both connection-refused (curl7/000),
generation0; live exact Qwen3.8-27B-4bit MLX/Metal acceptance still pending.

Next eligible implementation after THIS investigation's verified merge:
404-native-repair-return-boundary, existing umbrella404/F20. Preserve modes20–25.
New fixed opt-in protocol26 mode repair-return-boundary; no production storage
format or application-flow change. Challenge exact5keys mode,nonce,launch,sdk,
boundary; boundaries beforeCommit/afterCommit and launches1/2 only. Same canonical
private0700root, bounded4096challenge/8192report, strict duplicate/nonfinite/types/
identity/standalone or mixed option refusal, nofollow pinned control files.

Each boundary uses a fresh independent root and fixed supplied model
supplied-native-repair-return-boundary-model. Seed one fixed FAILED candidate/check
metadata record, working fingerprint, approval/board and selected raw session R1/
Tanalyze revision0/dispatch0, with no source folder/copy/SDK command or candidate
execution. Setup is explicitly failureSetupCalls1, never a successful real check.
Use actual ApprovedSourceProposer repair path with selected repairSessionBinding.
Reservation atomically persists repair attempt1 AND selected origin1 before the
fixed provider runs once. Gate terminal PROPOSED update before delegate commit or
after physical verification but before its Future resolves. No proposal return,
terminal return or deliveredReference; stored journal is reserved/no proposal
beforeCommit versus proposed/exact response+proposal hash afterCommit. Source
proposal text remains bounded private storage; reports contain only fingerprints.

Report exact32fields: version, mode, nonce, launch, boundary, stage, projectId, sessionId, boardTaskId, requirementId, requestedModel, attemptCount, attemptNumber, attemptStatus, attemptSha256, originSha256, failureSha256, originalSessionSha256, sessionRevision, sessionDispatchCount, storedResponseModel, storedProposalSha256, validatedResponseModel, validatedProposalSha256, declaredSourceSha256, deliveredReference, retainedReference, recordsBefore, recordsAfter, unrelatedBeforeSha256, unrelatedAfterSha256, counters.
Exact11literal record slots: working, repairOrigin, repairJournal, failureJournal, failedCandidate, session, execution, history, context, initialCompanion, repairCompanion.
Exact17counters: setupCalls, failureSetupCalls, proposalCalls, reservationCommits, reservationReturns, suppliedProviderCalls, proposalReturns, terminalAttempts, terminalCommits, terminalReturns, liveTransportAttempts, sdkAttempts, candidateEffects, unrelatedWrites, previewAttempts, sourceCopies, hostCreations.
Stage1 setup/failureSetup/proposal/reservationCommit/reservationReturn/provider/
terminalAttempt each1, terminalCommit0or1; all other counts0. Both recordsBefore
origin/journal=null, recordsAfter origin/journal=hash; preserved failureJournal,
failedCandidate,working,session hashes match and all execution/companion slotsnull.
ValidatedResponseModel/proposalHash only held stage; stored counterparts only
afterCommit and match held supplied metadata. Hash proposal via SHA256 of canonical
jsonEncode(proposal.toJson()), distinct from entire attempt and raw-origin hashes.

Parent pins exact bundle/source/root/report/challenge, validates same live owned
child and held report, kills/waits expected-9, then separate launch2 cold-read-only.
Cold counters all0, validatedResponse/proposal fieldsnull, exact raw map and original
selected origin/failed evidence/session/working preserved, no replay/rehydration/
SDK/source copy/new candidate. Cold retainedReference only afterCommit, exact
SelectedRepairRequestReference5keys version/projectId/attemptNumber/attemptSha256/
originSha256 jointly matched via origin.requireAttempt; beforeCommit no reference.
Persisted proposed repair is retained history, never delivered proposal or renewed
execution authority. Refuse foreign/changed origin, journal, capture, nonce/phase
without rewriting any record. No fresh attempt/retry/dispatch/promotion slice.

Private design /tmp/asg404-repair-return-report-design.json SHA256287279784ecb298fee58f4b4eeddb2d44be2c7bdd89c1217e8626f12e5429425
contains4placeholder samples, max3309bytes. These are design ONLY.
Validation: permanent strict parser/phase/cold/adverse Dart regressions with fresh
private POSIX roots and precise expected errors, portable host positive/adverse
contracts, format/analyze/full tests/web/PythonrequiredCI. Build NEW isolated Mac
restartfixture bundle and record exact source/whole-bundle hashes;4newnative
launches plus preserved36native20–25 matrix on SAME new bundle. Observe owned
process cleanup before release. Fixed new mode inspects existing SDK only and
never runs it; old20 retains original bounded SDK/receipt scope. No stable app
replacement, inference substitution, installs/downloads/cloud/deployment.

Investigation remains Pending review/requiredCI/verified merge; protocol26 source
and all new actual native observations remain PENDING. FullF20/CE01/#404/#400,
marketplace prerequisites and F23-last unchanged. One root writer; no independent
second task admitted. Time-to-merge/CI-provider timing/escaped-defect metrics unknown
unless separately measured; no escaped defect observed in this investigation.

Final investigation local checks:44focusedPASS, product32/inventory9PASS;
format559unchanged, analyze clean, fullFlutter2237PASS/12explicit skips, web built.
Three docs only; no application code, schema or approval-policy changes. Required
final-revision CI and fresh exact PR review still mandatory before merge.


### 2026-11-20 — #404 repair terminal investigation merged; native track started

PR777 protected expected-head merge6f2035c621bd24cbf79c012c4c585b1db411843b
verified GitHub main, mergedPR and fetched tree9a4aa176d869e1b182fe179910b6e88f83c65e8d.
Fresh review remote71047e0264d8b6431c697e895c622fc490fd177b/base d53e0b0a
found no blocker; threads empty. CI44678383505 Flutter136095598298 and
Python136095598570 both SUCCESS, every mandatory/post step passed. Local
44focused/product32/inventory9 PASS, format559unchanged/analyze clean/full2237PASS
12explicit skips/web built. Coordinator merged/outcome recorded; investigation
claim and integration released. Full404 remains OPEN; owner dirty edits untouched.

Immediately claimed dependency-ready task404-native-repair-return-fixture on
registered direct issue worktree. Root scope Dart fixture/test/router and shared
docs/inventory; sole isolated nativebuild resource assigned to root, none started
yet. Added strict bounded protocol26 challenge metadata, exact32/11/17 schema
constants and canonical selected-origin prefix. Two permanent parser tests PASS
cover four valid launch/phase combinations, foreign/mixed/bool/double/invalidpath,
valid duplicate-key payload and multibyte oversized inputs. Native runtime gate,
cold reader and actual app-crash evidence remain PENDING.

Delegated disjoint host track404-native-repair-return-host to reuse its clean
registered worktree; must acquire its own claim before editing only three Python
host/router/test paths, no nativebuild/inference/SDK command, stop clean and
handoff before root union integration. Exact contract/design remain the merged
32reportfields/11slots/17counters above; no placeholder treated as observation.
Model health remained unavailable at last04:59:08Z check with generation0. Native
implementation does not consume live runtime. No owner processes/stable app/last
working outputs changed; unavailable400/marketplace gate/F23-last preserved.


#404 native repair terminal fixture handoff:57focused Flutter regressions PASS,
including9new parser/nativeDB/adverse cases; Flutter and explicit fixture analyzes
clean. Actual selected repair reservation atomically creates attempt+origin, fixed
provider1 reaches held terminal proposed update before/after physical commit,
then independent read-only reopen preserves exact origin/failure/session/working
and rejects damaged origin/journal/capture. No source folders or SDK commands.

Contract clarification: SourceEditProposal has no toJson method. Proposal hashes
use the EXISTING persisted RepairAttempt.toJson()['proposal'] object (summary plus
ordered changes with path/before/after), SHA256(jsonEncode(...)); fixed supplied
payload uses identical structure. Response model remains separate provenance. This
corrects earlier contract shorthand; no model/storage/wire-format change. Supplied
failed snapshot includes GenerationInput fingerprints for metadata/app definition,
so existing approval guard remains enabled without writing source files. Setup
compile/fingerprint and style/import issues corrected before final checks; not
reported as application defects. Native process evidence still pending.

Accepted stopped clean host handoffb46327e64709998fdde523af3ecc1d89b44a675d,
148portablehost+6restartPASS. Neither portable mocks nor VM holds are native crash
proof. Writers must both release clean handoffs before union integration/new build;
root owns sole native artifact resource, owner runtime/stable app/last output and
unrelated dirty primary checkout remain preserved.


### #404 native selected-repair terminal boundary final local evidence

Integrated stopped clean/released root handoffe95be8965871058639ca966b9bd9a0d2f6d825f3
and hostb46327e64709998fdde523af3ecc1d89b44a675d under union claim
404-native-repair-return-integration. Sourcecommit5a755809b9635443c496a71f5d0e23c3a3e4aea7.
Protocol26 strict5-key challenge,32reportfields/11literal slots/17counters;
source proposal fingerprints use actual RepairAttempt.toJson()['proposal'] as
clarified above. Supplied FAILED check/snapshot metadata only; no SDK check or
source file was created for new mode. Existing project-input approval guard and
conditional storage validation remain enabled. No production app/schema changes.

NEW isolated native bundle:
/private/tmp/asg404-native-repair-return-derived/Build/Products/Debug/Automated Software Generator.app
Identity com.arsinha.asg.restartfixture, never installed/replaced stable app.
Whole-bundleSHA256 3437ef2da013a3ba581aa78a6a07f29d934276a82533c562d1dca20d2eb3c8ff.
607pinned source-inputSHA256 921bc58e9720ceeb881f29530751c3b72394341615674c71da45f2a5754c7f6c.
Three Python host-inputSHA256 66df5ad2cf1096969c8df78c311587bd6ee2a2616ddd42764a2d2baa7fb101bb.
All source bytes unchanged after all40actual native launches on this SAME bundle:
new26 before2+after2=4; preserved25 four,24six,23eight,22eight,21five,20five=36.
Old working bundles/observations retained at their original identities; this is
not40new capabilities. Fourteen separately hashed case receipts and exact roots
are listed in /tmp/asg404-native-repair-return-evidence-summary.json; source and
bundle receipts use matching source-manifest.json/bundle.json names.

In each new held stage, actual selected repair reservation/origin committed before
provider1 and no proposal/terminal return or delivered reference occurred. Before
physical terminal commit, durable attempt remains reserved with no stored proposal
or response; after physical commit it is proposed with exact supplied response and
proposal hash. Parent validated its same live child, killed/waited expected-9,
then separate cold app read retained exact attempt/origin/failure/session/working/
unrelated records, zero counters and no replay. Only afterCommit cold report
derived jointly matching retained-history reference; never proposal delivery or
execution approval. New mode has no live/SDK/source-copy/candidate/preview/host
effect. Legacy20 retains original bounded SDK/receipt scope. All owned fixture/
artifact-root processes settled, owner-started processes and last output preserved.

Local checks:57focusedPASS including9new parser/nativeDB/adverse cases; format560
unchanged, Flutter and explicit fixture analysis clean; fullFlutter2246PASS with
12explicit live skips; web built. Python148host+6restart+32product+9inventoryPASS.
Inventory regenerated unchanged. Setup compile/fingerprint/style corrections
completed before these final checks; no escaped defect observed. Fresh exact PR
review and every required CI step remain mandatory. FullCE01/F20/#404/liveQwen/
unavailable400 remain open; marketplace gate/F23-last preserved. No installs,
model downloads, unrestricted source execution, stable replacement, cloud or deploy.


### 2026-11-20 — #404 native repair terminal merged; actual HTTP track started

PR778 protected expected-head mergee41f8c97e431b68cda5e2b628da5ae435badee03
verified GitHub main, mergedPR and fetched treed474846a4dff97a5d463076f78fb35736b8ec2b5.
Fresh review remotec537d6b55747ba1432bbc41c253a2aa3c3bf280f/base6f2035c6
found no blocker; conversations empty. CI44680794531 Flutter136103428139 and
Python136103428551 every mandatory/post step SUCCESS; all9newPOSIX/metadata
tests activePASS in Linux logs. Native40samebundle607inputs and full2246PASS/12skip
local evidence retain exact identities above. Coordinator merge/outcome recorded;
union claim and integration released. Full404 remains OPEN; primary dirty edits
and every owner-started process/stable app/last working output preserved.

Immediately claimed next bounded task404-repair-http-journal-regressions under
existing404/F20 in registered direct issue worktree. Scope this ledger, PROGRESS,
AGENT_ENGINE, acceptance inventory and test/repair_request_http_journal_test.dart.
Concrete gap verified by test inventory: selected repairSessionBinding coverage
has no actual HTTP/loopback fixture, whereas initial requests have permanent
actualHTTP/nativeDB journal tests. This is a transport/storage regression slice,
not a new requirement, model claim or speculative backlog. One root writer only.

Acceptance: default HTTP proposer plus disposable nativeDB; physical selected
origin AND reserved attempt atomically committed before HTTP; withhold reservation
completion and observe no HTTP until release. Successful exact response returns
matching selected reference; wrong response ID consumes failed attempt with no
proposal/reference. Persistence refusal leaves neither origin/journal and sends
no HTTP. Actual DB close/reopen retains exact raw cohort and original failure,
selected raw session, working and unrelated records, no replay. Cleanup settles
original Future/provider/server before closing DB; callback assertions propagate.

Implemented these three permanent cases using synthetic SSE metadata on an
ephemeral loopback port and real default model transport. All3PASS; analyzerclean
after correcting one brace-style issue. No production app changes or SDK/source/
candidate execution, native app launch, live weight or genericplatform claim.
Logs /tmp/asg404-repair-http-journal-{focused,analyze}.log. Broader checks, required
CI, fresh review and verified merge remain pending for this in-progress task.
At2026-11-20T05:35:20Z fixed8765 /health and /v1/models both refused connection
(curl7/HTTP000), generation0. Root was sole readiness worker; no runtime started/
stopped/replaced. Live Qwen3.8-27B-4bit acceptance remains pending exact ready
MLX/Metal endpoint. Marketplace gate/F23-last/unavailable400 remain unchanged.


### #404 actual selected-repair HTTP/native journal final local evidence

Permanent test/repair_request_http_journal_test.dart now verifies3actual HTTP
scenarios with default production transport and synthetic SSE metadata. Physically
read selected origin+reserved attempt before reading/responding to request body;
reservation completion is held after atomic commit and no HTTP arrives until
release. Requested/stored response model identity and4096source ceiling checked.
Success returns exact jointly matched selected reference; wrong response ID
retains consumed failed attempt, null proposal/response identity/reference.
Reservation persistence refusal produces no HTTP and no partial origin/journal.
Actual DB close/reopen preserves exact raw cohort, original failure/session/working/
unrelated map and no replay. No source application or candidate/SDK/preview effect.

Cleanup releases held reservation, cancels service, drains ORIGINAL proposal
Future, closes server/subscription, awaits any entered callback before DB close
and deletion, then restores HttpOverrides. Main tests await original result and
callback assertions separately. Two private adverse cleanup probes PASS: cancel
during held reservation safely drains/tears down (including repeated close), and
an intentionally damaged private origin makes HTTP callback assertion observable
even though transport refusal is expected. These are fixture checks, not recovery
permission or live model/crash evidence. Private probeSHA25687c347d46243735100ea8f6c49c9d0e8d2ae74d6ccc56fef4ac1965f275f42a0;
/tmp/asg404-repair-http-cleanup-probe.dart.

Final local validation:48focusedPASS (3newpermanent+2privatecleanup+initialHTTP/
repair/context/reference regressions), format559unchanged, analyze clean, full
Flutter2249PASS/12explicit skips, web built, product32/inventory9PASS; regenerated
inventory unchanged. Logs /tmp/asg404-repair-http-journal-{regression,format,analyze,full,web,product,inventory}.log.
Only test+three owned docs changed; no application/storage/approval/transport
configuration change. Existing native40 observations remain tied to PR778's
original source/bundle and are not reused as new native acceptance here. Full
CE01/F20/#404/liveQwen/#400 remain OPEN. Fresh exact PR review, every required CI
step and verified remote merge remain required; no install/download/unrestricted
execution/stable replacement/cloud/deployment. No escaped defect observed.


### 2026-11-20 — #404 repair HTTP journal merged; live preflight track started

PR779 protected expected-head merge3052db3df00983935a66bb2b0e26065bf89f648e
verified GitHub main, mergedPR and fetched tree23123106631f23cda46e595df95ea7b4ae4057e1.
Fresh review remote69a9c32bc4bce2e90a3cd3758f3b44f854a491ba/basee41f8c97
found no blocker; threads empty. CI44682860119 Flutter136110151092 and
Python136110151439 every mandatory/post step SUCCESS. Linux logs confirm all3new
actualHTTP/nativeDB cases activePASS. Local48focused/full2249PASS12explicit skips,
format559/analyze/web/product32/inventory9 evidence preserved. Coordinator merged/
outcome recorded and integration/claim released. Full404 OPEN; owner dirty primary
checkout, owner processes and previous working outputs preserved.

Immediately claimed dependency-ready task404-selected-repair-live-preflight under
existing404/F20, registered direct issue worktree. Scope shared docs/inventory,
test/initial_request_live_readiness.dart and newtest/repair_request_live_test.dart.
Concrete gap: initial requests have a strict opt-in owner/native-journal harness;
selected repair now has actual synthetic HTTP/native reservation coverage but
no corresponding fixed-owner opt-in response-identity/cold-journal harness.

Acceptance: clearly shared strict source-budget readiness API with existing
initial entry points compatible; fixed8765GET health/models,5s/16KiB/no redirects/
retries, exact ready idle MLX/Metal/Qwen3.8-27B-4bit/singleinventory4096limits before
storage/proposer effects. Same selected-repair/nativeDB harness must have active
syntheticHTTP success/preflight-refusal checks and default explicit owner-live skip.
Named opt-in real case verifies actual response ID and exact nonnull selected
reference/proposed journal across DBclose/reopen with unchanged original failure/
session/working/origin/unrelated records. Returned source stays in memory/private
records only; no source application, candidate/SDK/preview/host/stable replacement.
No automatic retry after failed/timedout inference; client close does not prove
servergeneration stopped; reconcile runtime ownership before another live request.

Started by sharing unchanged strict guard body as requireSourceRequestLiveReadiness
and checkSourceRequestLiveReadiness, retaining compatible initial-named wrappers.
Fixed routes, limits, rejection conditions, timeout/body bound/client cleanup remain
unchanged. Existing guard16, initialsyntheticharness1 and selectedrepairHTTP3 all
PASS (20total); one existing initial owner-live case explicitly skipped, no live
claim. Log /tmp/asg404-selected-repair-live-preflight-start.log. New selected repair
opt-in harness still PENDING; broader checks/review/requiredCI/merge remain pending.
At2026-11-20T05:52:31Z fixed /health and /v1/models both connection-refused
(curl7/HTTP000); generation0. Root sole readiness/model worker; no server/model
starts/stops/downloads/substitution. One writer only; no second independent ready
task admitted. FullCE01/F20/#400/liveQwen/marketplace gate/F23-last preserved.


### #404 selected-repair opt-in source readiness harness final local evidence

Added test/repair_request_live_test.dart. The same nativeDB/default HTTP harness
actively passes supplied synthetic SSE and readiness-refusal scenarios; fixed
owner case is separately named and explicitly skipped unless ASG_REAL_INFERENCE
is enabled. Shared strict source readiness APIs retain compatible initial entry
points: fixed8765GET-only health/models, no redirects/retries,5s deadlines,16KiB
reply cap, ready idle MLX/Metal, exact single Qwen3.8-27B-4bit inventory and typed
4096source input/output limits, always-close client. This is bridge assertion
validation, not authenticated weights or later response identity proof.

Preflight precedes fixture storage/proposer effects. Actual native atomic origin
and reserved repair entry are physically observed before transport. Harness
requires nonnull exact response model, requested model/4096ceiling, proposed
attempt and jointly matching selected reference; source changes are compared
only in memory/private records. Actual DB close/reopen retains full raw map and
selected origin/failure/session/working/unrelated records, with no replay. Fixture
server callback failures remain observable after transport close. No candidate,
source application, SDK, preview, host, stable-app replacement or deployment.

Run the owner case ONLY as a standalone single worker after exact ready/idle
identity verification: flutter test --no-pub --dart-define=ASG_REAL_INFERENCE=true
test/repair_request_live_test.dart --name '^owner Qwen selected repair'. No retry
after timeout/failure and no assertion that client cancellation stops server
inference; reconcile owner runtime before another request. At2026-11-20T05:56:28Z
fixed health/models both connection-refused (curl7/000), readyfalse, generation0.
Therefore no owner-live test/inference attempted; live selected-repair acceptance
remains PENDING under404, not a skipped-pass or completed model acceptance.

Final local checks:64focusedPASS/2explicit owner-live skips, format560unchanged,
Flutter analyze clean, fullFlutter2250PASS/13explicit opt-in skips, web built;
product32/inventory9PASS, inventory regenerated unchanged. Logs
/tmp/asg404-selected-repair-live-preflight-{regression,format,analyze,full,web,product,inventory}.log
and bounded readiness receipt runtime-final.json. Two style issues corrected
before final checks; no escaped defect observed. Five files only:two test harness/
helper files plus three owned docs. No production/schema/approval/runtime change.
Fresh exact PR review, every required CI step and verified merge still required.
FullCE01/F20/#404/#400/liveQwen/marketplace gate/F23-last remain unchanged.


### 2026-11-20 — #404 selected-repair harness merged; runtime prerequisite started

PR780 protected expected-head mergece89dde3b714eba05581d075bc075fe3467b8f6d
verified GitHub main, mergedPR and fetched treeba119bc916e236a3909a6fb668a2b5d770696b48.
Fresh review remote414c3efbce29db70555efa96f271e2c54c7b1344/base3052db3d
found no blocker; threads empty. CI44684968177 Python136117002852 and
Flutter136117003197 everymandatory/poststepSUCCESS. New synthetic harness active
PASS in Linux logs, ownercase explicitly skipped. Local64focused/full2250PASS
13opt-inskips/format560/analyze/web/product32/inventory9 evidence preserved.
Coordinator merged/outcome recorded and claim/integration released. Harness
infrastructure delivered; actual initial/selected-repair live acceptance remains
PENDING under404, no weights/device/context-fit claim. Owner dirty edits and
processes/stableapp/last working outputs preserved.

Immediately claimed next bounded prerequisite task
404-owner-runtime-readiness-investigation underexisting404/F20 in registered
direct issue worktree. Scope thisledger/PROGRESS/AGENT_ENGINE only. Root sole
readiness/model worker; no second independent ready task admitted. Acceptance:
read-only fixedroutes,8765listener/sanitizedbridgeprocess observations, documented
checkpoint metadata without loading/hashing weights or reading owner preferences/
credentials/fullargv, then identify exact evidence/action to make live source
acceptance eligible. No start/stop/port/config/install/download/conversion action.
If independently exactready idle, atmostone standalone existingowner repair test
may run, with postrequest reconciliation; otherwise generation0 and pending.

Actual observation2026-11-20T06:11:59Z: health and models both connection-refused
(curl7/HTTP000); lsof8765LISTEN returned no entries (exit1, no error). Sanitized
process scan found no qwen_server.py or mlx_lm.server command candidates. This
means no listener/expected bridge process was observed at this sample, not proof
about all unrelated processes or owner intent. No process changed or terminated.
The documented existing checkpoint directory IS present:3weight files totalling
16,054,541,349bytes, config present and declaring4bit/group64. Only filenames/stat
and bounded config metadata read; no weights loaded/authenticated, no memory-fit
or MLX-compatibility inferred. ConfigSHA256
14b65a0ee06517060a6bbd979bb1a8ff54e7b304b1a1f01d54344b88b8285e85.
Private resolved path remains only in /tmp/asg404-owner-runtime-readiness-observation.json;
receiptSHA25677fc633afb1ad69a053fe752416ae1088d6eb15fbd2717e52420ce0d708f224f.
No rawprocessargv/credentials or privatecheckpointpath published. Generation0.

Specific F20 live prerequisite: an owner-started/recovered existing MLX service
must listen at fixed8765 and report ready/idle/Metal with the exact configured
Qwen3.8-27B-4bit ID and4096source budget before either standalone live test is
eligible. Setup guide's existing path is Save runtime setup → Start selected
model → wait Runtime reports ready/MLXMetal → verify Connect project chat ID/URL.
No download is indicated by the observed checkpoint-file presence; directory/config
metadata alone does not prove loadability or model identity. Next read-only work:
verify saved-launch/source readiness contract and record bounded owner action or
remaining uncertainty, then review/publish findings. FullCE01/F20/#400, marketplace
gate and F23-last preserved; no stable replacement/unrestrictedexecution/cloud/deploy.


### #404 runtime investigation admits independent duplicate-metadata repair

Current source contract verified: RuntimeSetupController.start re-scans selected
checkpoint, preserves explicit backend/Python setup and refuses an already-ready
runtime; NativeRuntimeHost reserves fixed8765 before starting packaged bridge
with model path, backend, model-id and owned parent-pid. Controller saves project
connection only after ready health reports both selected name and exact path;
Stop targets its owned process. These are current SOURCE contracts, not proof of
installed stable-app revision or the owner's saved settings (not read/changed).
Deterministic runtime setup/connection/redirect/source-readiness101fixtures PASS;
no owner runtime started. Existing missing listener, checkpoint metadata and
required ready/idle exactMLXMetal identity remain the live F20 prerequisite.

Independent concrete gap confirmed on current main with two private mocked-response
regressions: raw health JSON with status loading followed by duplicate status
ready incorrectly becomes RuntimeConnection.ready=true AND passes strict source
preflight. Baseline /tmp/asg404-duplicate-readiness-baseline.log has2expectedFAIL;
no network/inference/model involved. Introduction revision/user incidents unknown;
this is a reproduced latent validation defect, not an observed live-model failure.

Admit bounded task404-source-readiness-duplicate-metadata underexisting404/F20,
dependent only on mergedPR780, independent of the read-only runtime investigation.
Acceptance: reject duplicate raw health fields in product RuntimeConnection and
duplicate raw health/inventory fields in shared source guard BEFORE interpreting
status/model/path/source-budget readiness. Reuse existing pure duplicate-member
validator, preserve all valid unique replies, byte/deadline/redirect/cleanup rules
and initial API compatibility; locally authored product error, no raw serverdata
leak. Permanent adverse tests include conflicting/identical/escaped duplicate
keys, nested inventory IDs/limits, and unique valid controls. No model/port/backend
configuration or server-process changes; no response-stream parser expansion.

Second writer may claim ONLY lib/services/runtime_connection.dart,
test/runtime_connection_test.dart, test/initial_request_live_readiness.dart and
test/initial_request_live_readiness_test.dart in a distinct registered issue
worktree. Root keeps docs scope and sole runtime observations; neither writer
edits the other's paths. Both stop/commit/release handoffs before root acquires
union integration for one coherent validation/finding PR. Focused regressions,
format/analyze/fulltests/relevantbuild, exact freshreview/allrequiredCI/verified
merge remain mandatory. No current native40 evidence reused for revised source.


#404 owner runtime diagnostic handoff:101deterministic setup/connection/readiness
fixtures PASS plus1actual filesystem-only NativeRuntimeHost.scan observation.
The documented candidate is metadata-admitted and quantized,16,054,541,349bytes;
scanner's Qwen3.5 architecture-family detail is not an authenticated server model
ID. Candidate name is folder label Qwen3.8-27B-4bit; actual loaded identity still
requires health/inventory/response verification. No weights loaded or process
started; source ce89dde3 scan receipt /tmp/asg404-owner-checkpoint-scan.json.
Fresh06:21:50Z health/models still refused,8765listenercount0; generation0.
Private path/config metadata and prior06:11:59Z source observations remain tied
to their timestamps, not generalized to a loaded backend or installed-app version.

Required owner condition is an already approved compatible existingMLX service
started/recovered with explicitMLX/Metal, existingPython/checkpoint, fixed8765 and
exactQwen3.8ID/sourcebudgets, then ready/idle before a single standalone live
request. The saved Python/backend/preferences and stable binary revision were
not read or changed; package compatibility/memoryfit/weightauth remain unknown.
No download/upgrade/fallback or automatic service action was performed. Current
source protects app-owned Stop and avoids changing connection before path+name
match; these source facts do not prove owner settings or runtime loadability.

Independent latent duplicate-readiness defect reproduced without live runtime;
its two negative fixtures failed original source. Accepted stopped clean4path
handoff2aac3a788a048af9ba9674c0e7916947a2d6b063,111focusedPASS/2live skips,
format/analyzeclean, no live/mock identity conflation. This defect does NOT
explain the absent listener; no user incident observed, introduction unknown.
Both tasks await union integration/exact finalchecks/review/requiredCI/merge.
No previousnative40 observations reused as revised-source acceptance.


### #404 readiness validation integration — final local checks

Combined stopped/released diagnostic and duplicate-metadata handoffs. Original
private two-case reproducer now2PASS; fullFlutter2255PASS/13explicit opt-in skips,
format560unchanged, analyzer clean, web/Wasm dry run built. Product32/inventory9
PASS; inventory refreshed for changed runtime_connection source. Isolated normal
Mac debug build succeeded at /private/tmp/asg404-readiness-duplicate-derived with
validation bundle identity, no install/launch/stable replacement. This build is
not native runtime acceptance; previous40native observations retain original
source/bundle identities. Logs /tmp/asg404-readiness-union-{baseline-now,full,format,
analyze,web,macos,product,inventory}.log. Two original baseline failures demonstrate
a pre-existing duplicate-member validation defect, not an observed owner incident
or the cause of the absent8765listener. Source runtime remains unavailable and
owner inference acceptance PENDING; generation0. Required remote CI and fresh
exact-revision review/verified protected merge remain pending. Full404 stays OPEN.


### 2026-11-20 — #404 readiness validation merged; response identity investigation started

PR781 protected expected-head mergea81f925e8cb43eb6cdc53204d4c0addd824666a9
verified remote main/mergedPR/fetched treee3499e75e51f102d764788f2da5d397732bd0ccd.
Fresh review c12beb94336a765069a25d763a46ed6bb3ab9fdd/basece89dde3 found no blocker;
threads empty. Required CI44688550614 Python136128583776/Flutter136128584150 every
mandatory/post step SUCCESS; new cases activeLinuxPASS. Local2255PASS13explicit
skips/format560/analyze/web/isolatedMac/product32/inventory9. Coordinator merged/
outcome recorded, integration and claim released. Bounded readiness fix Done,
full404/liveQwen/#400 OPEN. No owner runtime change/inference/stable replacement.
Missing8765listener remains separate prerequisite; metadata is not loaded evidence.

Immediately claimed404-response-identity-ambiguity-investigation, sole docs writer
in registered direct issue worktree. Existing404/F20 covers response identity;
no new issue. Inspected LocalModel JSON compatibility/SSE frame jsonDecode before
model validation; duplicate model keys may hide earlier contradictory ID. PR781
excluded this boundary. Acceptance: mocked plain/escaped duplicate model cases
for both transports plus valid unique controls, exact-source evidence and bounded
follow-on remedy or no-gap result. No production edit/model/ownernetwork/nativeapp
execution. Byte/deadline/cancellation/privacy/lastworking guarantees retained.
Future publication requires checks/freshreview/protectedmerge. Marketplace gate/
F23-last preserved. Private fixtures are investigation evidence only.


#404 response identity investigation started on mergedsourcea81f925e. Four
private negative fixtures EXPECTEDFAIL: JSON and SSE each accept plain or escaped
duplicate model keys (foreign first, selected last), emitting Ready rather than
rejecting. Two valid unique controls PASS and retain completedResponseModel=selected.
MockClient only; no network/ownerinference. Logs /tmp/asg404-response-identity-
ambiguity-probe.log and unique-control.log; current production remains unchanged.
Concrete gap confirmed beyond PR781: reject ambiguous duplicate JSON members
before response-model evidence/content/metrics publication in JSON and SSE paths,
with permanent escaped/nested/malformed/privacy/cancellation controls. Do not
relax token/output/byte/deadline policy or older optional-ID compatibility.
This investigation's findings/contract await reviewable publication; implementation
needs its own claimed scope, required checks/freshreview/verifiedmerge. Existing
404 remains umbrella; no owner incident/introduction revision inferred.


### #404 bounded response metadata validation admitted

Task404-response-metadata-validation combines the stopped clean investigation
handoff4817a0f with its concrete remedy under existing404/F20. Dependency is
verified PR781 mergea81f925e; no dependency on an unmerged separate feature.
Sole writer owns three docs, local_model.dart, new regression test and inventory.
Acceptance: duplicate conflicting/identical/escaped/nested response members fail
before interpreting model/text/finish/metrics in JSON/SSE; valid unique and absent
optional-ID compatibility retained. Original bounds/deadlines/redirect/cancel/safe
errors unchanged. Permanent red/green tests include malformed/private diagnostic
and terminal duplicate after partial text with no completed identity/metrics.
Format/analyze/focused/fullFlutter/web/isolatedMac/product/inventory, finalreview/
requiredCI/protectedmerge mandatory. No ownerruntime/nativeapp/inference/install.


### #404 response metadata validation — final local evidence

Production LocalModelProvider now decodes valid JSON then reuses pure duplicate
member validator before interpreting success JSON or SSE metadata. Escaped keys
share identity; nested duplicates also rejected. Existing outer error boundary
keeps failures locally authored; bounds/deadlines/redirect/Stop/client ownership
and optional absent-model compatibility unchanged. Partial prior text can have
streamed, but ambiguous terminal metadata cannot publish completed identity or
metrics; source proposal validation/journal failure remains mandatory.

Permanent regression baseline4PASS/3expectedFAIL before fix, now7PASS; original
private4negative cases now4PASS. Focused30PASS including actual initial/repair
HTTP/native journals and architecture. FullFlutter2262PASS/13explicit opt-in skips;
format561unchanged, analyze clean, web built with Wasm dry run; isolated normal
Mac debug build succeeded /private/tmp/asg404-response-metadata-derived with
validation bundle ID, no install/launch/stable replacement. Product32/inventory9
PASS; comparison inventory refreshed. Logs /tmp/asg404-response-metadata-{before,
focused,private-now,format,analyze,full,web,macos,product,inventory}.log. One focused
command initially named a nonexistent initial fixture; corrected to actual
initial_request_http_journal_test.dart and reran successfully, no code workaround.
No owner incident/introduction revision inferred from reproducible latent defect.
This run fixedhealth/models both connection-refused, generation0; liveQwen pending.
Prior native observations retain their original source/bundle identities and do
not establish new native runtime acceptance. Required finalremoteCI/freshreview/
verifiedmerge remain pending; full404/#400/marketplace gate/F23-last preserved.


### 2026-11-20 — #404 generation metadata fix merged; journal tracks started

PR782 protected expected-head merged61323f2c496e03b45164ca8af437d77cfccfa76
verified remote main/mergedPR/fetched tree80bbe7e548827516ff5bc45a0f00d069968f9930.
Fresh reviewed d9db5d50646a5226867fe9d934ca934f6cd3186d/basea81f925e no blocker,
threads empty. Required CI44690504625 Python136134885870/Flutter136134886091 every
mandatory/post step SUCCESS; all7new cases activeLinuxPASS. Localfocused30,
full2262PASS13explicit skips, format561/analyze/web/isolatedMac/product32/inventory9.
Coordinator merged/outcome recorded and integration/claim released. Bounded
response validation Done; full404/liveQwen/#400 OPEN. Original ownerdirty checkout,
owner processes and working outputs preserved. No inference/model/stable changes.

Immediately start404-initial-ambiguous-response-journal and admit independent
404-repair-ambiguous-response-journal, both depend ONLY on verifiedPR782. Existing
404/F20 covers actual source response/journal acceptance; no new issue. Concrete
gap: transport mocks prove duplicate rejection; current actualHTTP/native journal
fixtures cover simple mismatch but not ambiguous duplicate IDs/terminal frames.
Root owns three docs and initial_request_http_journal_test.dart; delegated writer
may claim ONLY repair_request_http_journal_test.dart in distinct registeredWT.
Acceptance each: plain/escaped contradictory duplicates and terminal ambiguity
after valid partial source fail without completed identity; durable reservation
physically precedes HTTP, failed journal survives actual DBclose/reopen with
unchanged working/session/unrelated records, no retry/replay. Repair also retains
exact selected origin/failure and no delivered selected reference/proposal.
Keep positive/mismatch controls, callback failure visibility and drain-before-close
cleanup. No source application/candidate/SDK/model/nativeapp/owner runtime work.
Two disjoint writers maximum; root sole integration owner, handoffs stop/commit/
release before union. Focused/full checks, exactfreshreview/requiredCI/verified
merge mandatory. Full404/#400/marketplace gate/F23-last remain unchanged.


#404 initial ambiguous-response journal track started: extended actual default
HTTP/nativeDB fixture to six response modes (valid, ordinary mismatch, plain/
escaped duplicate model ID, plain/escaped terminal duplicate after valid source
frame) plus reserve-refusal control. All7PASS, log /tmp/asg404-initial-ambiguous-
journal-focused.log; format clean, diffcheck clean. New four ambiguity paths
retain failedLocally/native-reopen state, no completed response model/returned
hashes, unchanged full working/session/unrelated map and oneHTTP/no cold replay.
This is synthetic random-port HTTP/nativeDB evidence, not owner inference.
Repair writer separately claimed sole repair fixture and began analogous cases;
two valid disjoint claims, root sole integration owner. Broader checks, both
stopped handoffs, union integration/review/CI/merge remain pending. No prior
native/live observations reused for these tests. Full404/liveQwen/#400 OPEN.


#404 initial journal handoff final: valid source frame explicitly flushed before
plain/escaped ambiguous terminal frames. All7actualHTTP/nativeDB scenarios plus
7transport duplicate and1architecture case PASS (15total); focused analyzer clean,
format unchanged and diffcheck clean. Log /tmp/asg404-initial-ambiguous-journal-
regression.log; no ownernetwork/inference/nativeapp/build or source production
changes. Root stopping four-path initial/docs handoff before union; repair
writer independently finalizing its sole test path. Acceptance remains bounded
synthetic journal behavior, full404/liveQwen/#400 pending.


### #404 ambiguous HTTP journal integration — final local evidence

Both stopped clean handoffs accepted and claims released: initial0db7f07f0d0f8a
and repair97fa4fad82dbe07b. Sole union claim404-ambiguous-response-journal-integration
then combined their disjoint files. Initial terminal scenarios strengthened to
flush an actual valid partial source fragment, with remainder in the ambiguous
terminal frame, matching repair. These prove failed durable journals after valid
partial source bytes, not a claim that a client observed bytes at a timed instant.

Each actualHTTP/nativeDB fixture now7PASS: valid, ordinary mismatch, plain/escaped
contradictory duplicate IDs, plain/escaped terminal duplicates and reserve refusal.
Both physically verify reservation before HTTP; invalid responses retain failure
and no completed identity/evidence, actual close/reopen raw-map equality and
oneHTTP/no replay. Repair retains matching selected origin and original failure,
no proposed source or delivered selected reference. Existing callback error
visibility and cancel/drain-before-close retained. Eight added scenarios total.

Finalcombined32focusedPASS, fullFlutter2270PASS/13explicit opt-in skips, format561
unchanged, analyzer clean, web/Wasm dry run built, product32/inventory9PASS. Logs
/tmp/asg404-ambiguous-journal-{regression,full,format,analyze,web,product,inventory}.log.
Only two tests and three docs changed; production runtime/schema/inventory inputs
unchanged. No new nativeapp execution/build/install or model/owner process changes;
prior native observations retain their original identities. At2026-11-20T07:04:05Z
fixedhealth/models unavailableURLError, generation0; private bounded receipt
/tmp/asg404-ambiguous-journal-runtime-status.json. Full404/liveQwen/#400 remain OPEN.
Required exactfreshPRreview/allrequiredCI/verifiedprotectedmerge still pending.
No product defect newly discovered in these journal checks; metadata defect and
its before/after evidence remain recorded under mergedPR782. Marketplace/F23-last
preserved, no cloud/deployment/unrestricted execution.


### 2026-11-20 — #404 ambiguous SSE journals merged; JSON compatibility tracks started

PR783 protected expected-head merge78b06b033e9b13c23c4ba9484d9df4998c36303a
verified remote main/mergedPR/fetched tree550184bc387c256b440c02bc2c89f12e15f8c115.
Fresh reviewedf434a6e8c765cb677abd7012fdea1753aa6f3556/based61323f2 no blocker,
threads empty. CI44692502912 Python136141389903/Flutter136141390296 every mandatory/
post step SUCCESS; eight new actualHTTP/nativeDB scenarios activeLinuxPASS.
Local32focused/full2270PASS13explicit skips/format561/analyze/web/product32/inventory9.
Coordinator merged/outcome recorded; integration and union claim released. Both
bounded SSE journal tracks Done; full404/liveQwen/#400 stay OPEN, ownerdirty
checkout/processes/lastworking outputs preserved. No source apply/inference/native
app/stable replacement/deployment.

Immediately claim404-initial-json-response-journal and admit independent
404-repair-json-response-journal underexisting404/F20, both depend ONLY on verified
PR783. Concrete gap verified in source/evidence: LocalModelProvider supports
non-streaming JSON compatibility, both actualHTTP/native journal fixtures solely
serve SSE. Transport mocks alone do not prove durable source/repair JSON outcomes.
Root owns initial fixture plus three shared docs; delegated writer may claim
only repair fixture in distinct registeredWT. Preserve seven SSE/control cases
and add actual application/json valid, wrongID, plain/escaped contradictory model
and absent response-model scenarios. Valid replies complete source hashes or repair proposal/reference; explicit
conflicting IDs fail. An absent optional ID retains unknown response identity,
without inventing it from requested configuration.
Verify physical durable intent before HTTP, unchanged full working/session/failure/
origin/unrelated map, actual DBclose/reopen/no retry or replay, callback visibility
and drain cleanup. No production optional-ID policy change, source apply/candidate/
SDK/model/owner runtime/nativeapp work. Two disjoint writers, one integration owner;
stopped released handoffs before union; required fullchecks/freshreview/CI/merge.
Marketplace gate/F23-last and deferred400 remain unchanged.


#404 JSON compatibility start finding: initial valid/wrong/plain+escapedduplicate
cases PASS; the first missingID assertion incorrectly assumed strict source
refusal and FAILED (refusal null). SourceEditProposer explicitly compares only
nonnull response IDs, and ApprovedSourceProposer preserves optional identity.
This is existing deliberate unknown-ID compatibility, not a demonstrated defect.
Corrected acceptance: valid missingID may return validated source with null
responseModel; requested model remains separate. No fabricated model proof or
new rejection policy. Owner-live harness still requires exactnonnull identity
for live acceptance. Source production unchanged; repair writer notified.


#404 initial JSON journal track now12PASS: seven preserved SSE/control scenarios
and five actualJSON valid/wrong/plain+escapedduplicate/absentID cases. Valid
absentID succeeds with nullresponseModel retained through actual DBreopen, while
requested identity, valid returned hashes and working/session/unrelated records
remain truthful and unchanged. Explicit wrong/ambiguous IDs fail; oneHTTP/no
reopen replay retained. Log /tmp/asg404-initial-json-journal-focused.log; format/
diffcheck clean. Initial false strict-ID expectation corrected from inspected
source contract, no production change. Repair writer independently confirmed
same nullableidentity behavior and is testing corrected compatibility acceptance.
Both tracks remain owned/unmerged; broaderchecks/freshreview/CI/merge pending.
No inference/owner runtime/nativeapp/SDK/source application. Full404/liveQwen OPEN.


#404 initial JSON handoff final:12actualHTTP/nativeDB cases plus7transport and
1architecture case PASS (20total), focused analyzer clean, onefileformat unchanged,
diffcheck clean. Log /tmp/asg404-initial-json-journal-regression.log. Current
optional response identity remains nullable: absent-ID valid reply retains null
responseModel and real returned hashes through reopen, not an authenticated model
claim; conflicting IDs remain failure. Initial stopped fourpath handoff follows;
repair writer owns only its fixture and is independently stopping. No production/
model/runtime/nativeapp/SDK/source application or live acceptance.


### #404 JSON journal integration — final local evidence

Both clean stopped handoffs accepted/released: initial6c9193e1985e8e67/tree719c0ad4
and repairf1d4f9a34b60ba6b/tree8000e9ac. Sole union task404-json-response-journal-
integration combines only two fixture files and three docs. Each fixture now
12actualHTTP/nativeDB PASS: seven preserved SSE/reservation cases plus JSON valid,
wrongID, plain/escaped duplicate model and absent-ID compatibility. Requests
still send stream:true; actual application/json message.content responses enter
the production compatibility path. Explicit invalid IDs fail without returned
evidence; valid absent-ID replies succeed while observed identity remains null.
Requested model, valid source hashes/proposal/reference, origin/failure/session/
working/unrelated records stay truthful through actual DBclose/reopen/no replay.
Callbacks remain observable and pending work drains before DBclose.

The initial strict missing-ID expectation was incorrect (each fixture originally
11PASS/1FAIL); source contract inspection corrected test acceptance, without any
production policy change. SourceEditProposer only rejects nonnull conflicts;
nullable ModelRequestProvenance preserves request-only v1metadata. Null response
identity never proves loaded model identity; owner-live harnesses still demand
exact nonnull response identity. No new product defect inferred.

Final42focusedPASS, fullFlutter2280PASS/13explicit opt-in skips, format561unchanged,
analyzer clean, web/Wasm dry run built, product32/inventory9PASS. Logs
/tmp/asg404-json-journal-{regression,full,format,analyze,web,product,inventory}.log.
No production/schema/runtime-inventory change, nativeapp build/launch/install,
model/inference/ownerprocess/sourceapplication/SDK/deployment. Old native/live
observations retain original identities, not reused as current acceptance. Fresh
bounded owner route receipt /tmp/asg404-json-journal-runtime-status.json records
this run's status separately; no generation requested. Full404/liveQwen/#400 OPEN;
required exactPRreview/allrequiredCI/verifiedmerge pending. Marketplace/F23-last
preserved.


### 2026-11-20 — #404 JSON journals merged; MLX environment prerequisite started

PR784 protected expected-head mergea88926e25ea2c80aea2a1af8d5fc7df972b77ed9
verified remote main/mergedPR/fetched tree4b46c71e24d8d3e79def2136213eee18ced8a2a9.
Fresh reviewedb3554908374b8f169f6c10e0d60788d1d7bbf0ad/base78b06b03 no blocker,
threads empty. CI44694810001 Python136148901227/Flutter136148901616 every mandatory/
post step SUCCESS; ten new actualJSON/nativeDB cases activeLinuxPASS, nullable
legacy observedidentity retained. Local42focused/full2280PASS13explicit skips/
format561/analyze/web/product32/inventory9. Coordinator merged/outcome recorded,
integration and claim released. Both bounded JSON tracks Done; full404/liveQwen/
#400 remain OPEN. Ownerdirty checkout/processes and lastworking outputs preserved.

Immediately claimed404-mlx-environment-prerequisite-investigation in registered
issue worktree, sole docs writer. Existing404/F20 covers unavailable live source
acceptance; no new issue. Concrete prior diagnostic uncertainty: checkpoint metadata
exists but no owner8765listener; current existing Python package discovery and
compatibility are unknown. History identifies a project-local existing MLX
environment candidate. Acceptance: bounded stat/config/package metadata and at
most one reviewed --capabilities-only CLI on that existing Python; no --model,
--probe-devices, frameworks/devices/weights load, server start/stop, install,
download/conversion/fallback or owner saved preferences/credential access.
Private paths stay local. Discovery cannot prove selected saved setup, Metal
readiness, weight identity/integrity, memory fit or inference. Bounded owner
health/models GET status only; record exact evidence/action needed for live
acceptance. No second independent task admitted; root sole runtime observer.
Docs publication still requires checks/freshreview/allrequiredCI/verifiedmerge.
Marketplace gate/F23-last/deferred400 preserved, no stable replacement/cloud/deploy.


#404 MLX environment prerequisite started with actual read-only observation at
2026-11-20T07:34:53Z/sourcea88926e2. Historically documented project-local existing
Python and venv config are present. Bounded distribution metadata declares
mlx0.32.4, mlx-lm0.32.2, mlx-metal0.32.4, huggingface_hub2.3.0, tokenizers0.23.3
and transformers5.20.2; existing qwen3_5 module file present. These are metadata/
file observations, not package integrity or loaded model compatibility evidence.
Exactly one reviewed --capabilities invocation exited0,574stdoutbytes/0stderr,
within10s: Darwinarm64, MLX host_supported=true, missing_dependencies=[],
readiness=unverified, device_ready=null, model_compatible=null. No --model or
--probe-devices, device/framework/model loading, server start or generation.
Legacy Torch dependencies absent does not call for installing or switching them.

Both fixedhealth/models remain unavailableURLError; generation0. Thus a candidate
existing MLX environment is dependency-discoverable, but this does not prove the
owner's saved selected Python/backend/stable binary, Metal readiness, weight
identity/memoryfit or live inference. No preferences/credentials/processes changed
or read. Specific F20 live prerequisite remains owner-started/recovered approved
MLX service on8765 reporting ready/idle/Metal, exactQwen3.8-27B-4bit and4096source
budgets, then one standalone request with exactnonnull response identity.
Private candidate path only in /tmp/asg404-mlx-environment-prerequisite-receipt.json;
SHA2563e750fe4ec0c1dab6a4bd7c58e1a80cb445263884c9e098e39eb636abf68eafc.
Investigation still owned; source/launch-contract cross-check, docs checks and
reviewable publication pending. No install/download/conversion/fallback/stable
replacement/cloud/deployment. Full404/liveQwen/#400 remain OPEN.


### #404 MLX environment prerequisite — completed local investigation

Cross-checked exact current source: qwen_server --capabilities returns before
model path/config/load/server construction; default discover_capabilities uses
module discovery without probe_device. Actual07:34candidate command omitted
--probe-devices. Managed NativeRuntimeHost.discover instead explicitly adds that
flag, so the observed dependency-only receipt is NOT an app Inspect capabilities
device result. Actual managed start separately reserves8765 and passes explicit
backend/model/path/ID/parent-pid; controller saves connection only after ready
health matches selected candidate name AND path. Source contracts do not prove
installed binary revision, saved owner selection, existing package integrity,
Metal readiness, checkpoint loadability/memoryfit or live response identity.

Existing dependency-discovery regression suite67ran/1explicit skip (66PASS),
product32/inventory9PASS. These fixtures and CLI smoke checks are separate from
the single actual candidate environment command; no candidate device probe or
weight load was run. FullFlutter2280PASS/13explicit opt-in skips, format561unchanged,
analyzer clean, web/Wasm dry run built. Logs /tmp/asg404-mlx-env-{backend-fixtures,
product,inventory,full,format,analyze,web}.log. Three documentation paths only,
no production/environment/model/source changes. All prior native/live evidence
retains its original identity, not reused as new acceptance.

Specific remainingF20 prerequisite is the approved owner MLX service ready/idle
on8765, exactQwen3.8-27B-4bit model inventory with4096sourcebudgets, then exact
nonnull response identity in a standalone source request. The historical Python
candidate currently has discoverable MLX dependencies; no install/download or
Torch fallback is indicated by this check. Saved setup choice and successful
load remain unverified, and fixedhealth/models were unavailable at07:34:53.
Required exactfreshPRreview/allrequiredCI/verifiedmerge remain pending for these
findings. Full404/liveQwen/#400 stay OPEN, marketplace gate/F23-last preserved.


### 2026-11-20 — #404 MLX prerequisite findings merged; Git inventory boundary started

PR785 protected expected-head merge232c6a76b6c8528cab999f602317496e23092d3d
verified remote main/mergedPR/fetched tree2822d8c2cc663b003c2e1c95a9227bc81d40eeeb.
Fresh reviewed34cdb74b608eaa64336b69ba90d7009de5ab6f6e/basea88926e2 no blocker,
threads empty. CI44696629235 Flutter136154822017/Python136154822467 every mandatory/
post step SUCCESS. Localbackend67run1skip/fullFlutter2280PASS13skips/format561/
analyze/web/product32/inventory9. Coordinator merged/outcome recorded, integration
and claim released. Bounded dependency investigation Done; full404/liveQwen/#400
remain OPEN. MLX dependencies discoverable does not prove loaded device/model
readiness; owner8765ready/idle exactmodel/inventory/budgets/response is still needed.
Ownerdirty checkout/processes/lastworking outputs preserved.

Immediately claimed404-git-inventory-boundary-investigation under existing404/F20,
sole docs writer in registered issue worktree. Canonical existing-gap table maps
F07/F08/F20 to read-only Git workspace inventory before imported-source changes.
Code search/imported workspace confirms only inspected folder/planning UI, no
Git inventory service/status behavior. Concrete prerequisite: establish whether
naive status can execute repository-configured clean filters/fsmonitor commands,
then bound safe refusal/override conditions before any future Git adapter.
Acceptance: disposable private local repositories only, no remotes/network,
isolated global/system config/emptytemplates; two known inert marker helpers may
write only within owned fixtures. Measure command execution and before/after
HEAD/index/tracked hashes, controlled refusal/override, bounded output/deadlines,
cleanup. No owner repository hook/config execution, credentials, clone/fetch,
model/runtime/nativeapp/install/deploy effects. Record actual Mac/Git/source
identity and narrow next implementation contract; no arbitrary Git safety/support
claim or enabled UI. Root sole writer, no second independent task admitted.
Future publication requires docs checks/freshreview/requiredCI/verifiedmerge.
Marketplace gate/F23-last/deferred400 and all approval limits preserved.


#404 Git inventory boundary investigation started with five actual controlled
checks on Darwinarm64, git2.54.0(AppleGit-157), source232c6a76 at2026-11-20T07:50:54Z.
Disposable repositories had empty templates, no remotes/network, isolated global/
system Git config, pager/hooks disabled and optional locks off. Only two reviewed
inert fixture helpers wrote known marker files; no owner repository was touched.
Baseline dirty status ran no helper. Configured clean filter DID run its marker
command during status, despite read-only intention/hooks disabled. Reading only
local filter key names with --no-includes allowed a controlled preflight refusal
before status, without marker execution. Separately configured fsmonitor DID run
its marker during status; explicit core.fsmonitor=false prevented that marker
while still reporting dirty. HEADfile/mainref/index/config/trackedfile hashes
remained unchanged in measured status/preflight cases; marker side effects were
confined to owned fixtures. Cleanup completed. All5checks PASS after strengthening
ref hashing; private script /tmp/asg404-git-inventory-boundary-probe.py and receipt
/tmp/asg404-git-inventory-boundary-receipt.json, SHA256
b847535d577d5fc6ef02f1746b8f786723c99f8103ba1858149cbcfe66a46c06.

This is a prerequisite finding, not an ASG product defect or complete Git sandbox.
Current imported workspace has no Git inventory feature to enable. Next bounded
implementation contract must validate contained Git topology/config before any
status invocation; refuse unsupported filter/include/worktree indirection rather
than executing repository commands, isolate inherited config/environment, disable
fsmonitor/hooks/pager/optional writes, bound process/output/path handling and
retain explicit unsupported results. Known-key fixture refusal is not a general
parser or proof of safety for arbitrary repos. An imported-folder open currently
grants no execution approval; any future native Git inspection needs its own
explicit bounded action/permission and truthful branch/dirty/conflict evidence.
No clone/fetch/sourceediting/auth or broad support claim. Investigation remains
owned; further source/contract review and publication checks pending. No model/
runtime/nativeapp/install/cloud/deploy effects; full404/liveQwen/#400 stay OPEN.


### #404 Git inventory boundary — extended controlled findings

Extended same disposable probe at2026-11-20T07:54:33Z on sameGit/source/host: eight
checks PASS. A filter-key preflight first found no keys; controlled config update
then installed the known inert filter before status, which DID execute it. This
is deterministic check/use interleaving, no timing race required. Preflight alone
cannot guarantee a later arbitrary-repo status avoids repository commands.
Configured-filter and configured-fsmonitor fixtures separately returned main/
40hexHEAD via symbolic-ref/rev-parse without their marker helpers running; this
measures those commands on two controlled configs, NOT complete safety for all
Git configs/topologies/versions. Original five-case receipt retained byte-identical
SHA b847535d; extended receipt /tmp/asg404-git-inventory-boundary-extended-receipt.json
SHA256dfcebd86407aa10f2b473928e1409473ba35c604be7c23f911d3cae17ad13e12,
script /tmp/asg404-git-inventory-boundary-extended-probe.py. No ownerrepo/remotes
or model/runtime effects; HEAD/mainref/index/config/working bytes unchanged in
status cases except explicit controlled config intervention and fixture markers.

Refinement: original required preflight/overrides are necessary examples, NOT
sufficient authorization to execute status after mutable config checks. Any
future status adapter needs an enforced immutable configuration/snapshot or
separately proven isolation boundary and typed unsupported behavior. Do not
enable naive status in imported workspace. A bounded independent first slice
can instead read contained Git HEAD/ref metadata WITHOUT invoking Git, shell,
hooks, filters, config, index or network. Use descriptor-anchored no-follow bounded
regular-file reads; reject symlink/gitfile/worktree indirection and unsupported
formats. Report branch/detached/declaredOID only, working-tree/aheadbehind/conflict
unknown, never invent verified commit/content identity or action approval.
This is the next narrow implementation contract after reviewed merge of findings,
not a claim of an existing Git inventory feature or full Git sandbox.


### #404 Git inventory boundary — final local evidence

Source/contract review confirms the queued imported-workspace inventory is not
yet implemented; model-download Git URLs are a separate explicitly selected
model setup flow. Existing imported workspace grants no execution approval.
Eight controlled Git checks establish only the measured config/helper cases;
mutable preflight is insufficient for future arbitrary-repo status. Narrow next
slice is a command-free contained HEAD/ref metadata reader, with declaredOID/
branch observation only and dirty/aheadbehind/conflict explicitly unknown.
It must never spawn Git or read executable config/filters/hooks/index, and must
refuse unsupported indirection/symlinks/oversized/malformed metadata with bounded
no-follow reads. No full Git support or new execution authority is implied.

FinalFlutter2280PASS/13explicit opt-in skips, format561unchanged, analyzer clean,
web/Wasm dry run built, product32/inventory9PASS. Logs /tmp/asg404-git-boundary-
{full,format,analyze,web,product,inventory}.log. Original and extended private
probe receipts retain their separate exact SHA256 identities; no owner repo,
remote/network, credentials, model/runtime/nativeapp/install/sourceapplication/
cloud/deploy effects. Three docs only. No ASG product vulnerability claimed: no
Git inventory exists yet. Required exactfreshPRreview/allrequiredCI/verifiedmerge
remain pending. Full404/liveQwen/#400, marketplace gate/F23-last preserved.


### 2026-11-20 — #404 Git boundary findings merged; command-free HEAD reader started

PR786 protected expected-head mergeb95e9db62ee848f0a5f278b0cb215af0632a8b6d
verified remote main/mergedPR/fetched tree9873325ff018a682528f227cc3bd7c49ce199bf4.
Fresh reviewed84f32461a6c3cc8e66e18a5a1a7b79968989fc01/base232c6a76 no blocker,
threads empty. CI44698931166 Flutter136162330521/Python136162330726 every mandatory/
post step SUCCESS. Eight controlledGit checks/local2280FlutterPASS13skips/format/
analyze/web/product32/inventory9 retained. Coordinator merged/outcome recorded;
integration and claim released. Bounded investigation Done, full404/liveQwen/#400
OPEN. Ownerdirty checkout/processes and lastworking outputs preserved.

Immediately claimed404-command-free-git-head-reader under existing404/F20, sole
writer in registeredissueWT. One coherent internal prerequisite, no new issue: a
stdlib POSIX helper observes literal contained loose .gitHEAD/ref declarations
without invoking Git/shell/config/index/hooks/filters/objects/network or writes.
Owns tools/git_head_metadata.py, its deterministic tests, existingCIruntimejob
step and three docs. Fixed --root/versionedJSON, no rawpath/errors. Descriptor-
anchored nofollow directories/regular files, bounded stable reads/cleanup; reject
links/hardlinks/FIFO/malformed/oversize/traversal/.gitfile/commondir/gitdir/reftable
and ANYpacked-refs presence. Packs can be legitimate: unsupported, not corrupt
or unborn. Missing loose target unresolved. No automatic retry on changed input.

Read-only design review clarified essential truthfulness: ignoring config means
no certification of repositoryformat/objectformat/refstorage. Return ONLY literal
declared_ref/declared_oid/head_form/oid_source, git_state_verified=false and
workingtree/aheadbehind/conflict unknown. DeclaredOID does not prove object or
commit existence, atomic snapshot, authenticatedGitstate or execution approval.
Descriptor anchoring is not a general OSsandbox against hostile mounts/writers.
Initial branch path grammar is an explicit strict subset. No appUI integration
or nativeGit execution enabled by this helper; future integration needs its own
reviewed bounded action. Test positive/missing/refusal/descriptorrace/mutation/
no-forbidden-read/process/unchanged-file cases and add CItest step preserving
read-only permissions/pinnedactions/protection. Fullchecks/freshreview/requiredCI/
verifiedmerge mandatory. No second independent writer task admitted; read-only
researcher made no edits/claims. No model/runtime/nativeapp/install/cloud/deploy.
Marketplace gate/F23-last/deferred400 retained.


#404 command-free HEAD reader started: tools/git_head_metadata.py implements
fixed --root/versionedJSON literal loose-file observations using anchored
POSIX nofollow descriptors, bounded regular single-link files and held-fd/name
stability checks. It never imports/spawns Git/subprocess/shell or reads config,
index, objects, hooks, filters, packed refs or network; rejects knownindirection
markers and allpackedrefs presence. Symbolic loose declaration/direct40or64hex/
missingtarget states retain explicit unverifiedGitstate and unknown working/
ahead/conflict fields. No appUI/manifest/authority integration performed.

Initial12disposableMac tests PASS: symbolic/direct declarations, unresolvedtarget,
no direct.git, packedpresence without read, HEADsymlink/traversal/FIFO/hardlink
refusal, forbidden-read/process spies, unchangedbytes and actual isolated Python
CLI JSON. Log /tmp/asg404-git-head-reader-start.log. This is START evidence only:
expanded descriptor race/mutation/malformed/topology/cleanup tests, runtimeCI
registration, broaderchecks/freshreview/verifiedmerge remain pending. No OSsandbox/
atomicrepo snapshot, verifiedcommit/Gitstate or allplatform claim. No ownerrepo/
model/runtime/nativeapp/install/deploy effects. Sole writer lease remains active.


### #404 command-free HEAD reader — final local implementation evidence

Internal stdlib helper now emits version1 literal-file-declaration JSON only:
observed/unresolved/not_present/unsupported/invalid/changed/unavailable, fixed
reason, declared_ref/declared_oid/head_form/oid_source, git_state_verified=false
and workingtree/aheadbehind/conflict unknown. It does not interpret config or
certify repositoryformat/refstorage/object/commit state. Canonical absolute root
and ref components use POSIXdirfd nofollow handles; bounded regularsingle-link
HEAD/ref reads verify before/opened/after/named identity and held descriptors.
Known .gitfile/link/commondir/gitdir/reftable/ANYpackedrefs are refused without
following/reading; no Git/subprocess/shell/config/index/objects/hooks/filter or
network access, writes, automatic retry or rawpath/error echo. Packed repos are
unsupported, missing loose targets unresolved, never inferred unborn.

Read-only source review found and root fixed prepublication mutation gaps:
poststat-open disappearance/replacement nowchanged, finalreadset disappearance
nowchanged, finalmarker absence checked AFTER files/missing; cached host capability
check includes statfollow_symlinks so syscallspies exercise realIO. Deterministic
late-marker regression originally26PASS/1FAIL (observed instead ofchanged), now
PASS. These were unmerged helper defects, not escaped app incidents. Subsequent
read-only source pass found no new blocker within stated non-sandbox scope.

33focusedMac tests PASS: literal symbolic/direct40/64 declarations, unresolved/
missing/invalid/malformed/oversize cases, root/.git/refdir/leaf link/swaps, outside-
authorized-root symlink/hardlink refusal, FIFO, stat-open/duringread/finalreadset/
marker/missingtarget mutation, no forbidden reads/processes, unchangedbytes, FD
cleanup on success/failure/changed and actual isolatedPythonCLI fixedJSON/stderr.
Logs /tmp/asg404-git-head-reader-{final-focused,marker-before}.log. RegularFS calls
can still block; caller needs a process deadline. No OSsandbox, hostilemount/ABA
or atomicrepository snapshot guarantee. ASCIIref grammar is an explicitsubset.

Existing Python runtimeCI job adds only this deterministic suite; job names,
read-only permissions, pinnedactions/protection unchanged. Localcoordinator20/
product32/inventory9PASS, fullFlutter2280PASS13explicit skips, format561unchanged,
analyzer clean, web/Wasm dry run built. Logs /tmp/asg404-git-head-reader-{coordinator,
product,inventory,full,format,analyze,web}.log. No appUI/asset/nativeGit/status or
new approval authority is integrated. Ownerrepo/model/runtime/nativeapp/install/
cloud/deploy untouched; old native/live evidence retains originalidentity.
Fresh exactPRreview/allrequiredCI/verifiedmerge pending; full404/liveQwen/#400,
marketplace gate andF23-last retained. This is one internal safety prerequisite,
not full imported-repository support.


### 2026-11-20 — #404 command-free reader merged; manual imported metadata flow started

PR787 protected expected-head merge6090d539b9bcecc59387aa78fcb845e01ef8b480
verified remote main/mergedPR/fetched tree0b4d4ff92f9319f3ba7a6ba4ec0a9ce84dffcacf.
Fresh revieweda69b1914a96b95b86e9a9ce9f0cfadc2267f68c8/baseb95e9db6 no blocker;
threads empty. CI44702064960 Python136172579595/Flutter136172580047 every mandatory/
post step SUCCESS; new33helpertests activeLinuxPASS. Local33Mac/coordinator20/
product32/inventory9/fullFlutter2280PASS13skips/format561/analyze/web retained.
Coordinator merged/outcome recorded and integration/claim released. Bounded
internal helper Done; full404/liveQwen/#400 remain OPEN, no appUI/status/authority
or complete isolation claim. Ownerdirty checkout/processes/outputs preserved.

Immediately claimed404-imported-git-metadata-inspection underexisting404/F20, one
coherent manual imported-folder read flow, solewriter. Strict pure model validates
version1 helper output (duplicate/oversize/extra/malformed/contradictory schema
rejected with private fixed errors). MVC controller/host/view adds explicit scoped
read confirmation, no scan on open or savedplan/model authority, no storage writes.
NativeMac existing configured absolute trusted interpreter only (resolved outside
inspectedroot), packaged helper through -I -S -B in owned tempcwd, bounded output/
deadline/cancel/kill/reap/cleanup; no PATH search, install/model/Git/projectcommand.
Absent/corrupt/relative environment or unsupportedweb/host refuses honestly.

UI labels literal file declarations, not current verified branch/commit/Gitstate;
workingtree/ahead/conflict unknown. Packed/indirected/mutated results remain typed
unsupported/changed. Busy/disposal/startup/timeout/cancel/late-result tests and
visible stale prior observation on failure; no setting/runtime/process replacement.
Owned scope includes model/hostfactory/native/stub/controller/panel/importedview,
packaged asset/pubspec, focused tests, inventory and three docs. Future integration
requires actual disposableMac helper evidence, relevantweb/isolatedMacbuild/UI
checks, product/inventory, allrequiredCI/freshreview/verifiedmerge. No cloned/fetched
repo, arbitrary editing/execution, remoteauth, stableapp/install/cloud/deployment.
No second independent writer task admitted because MVC/host/view share one frozen
protocol and user outcome. Marketplace gate/F23-last/deferred400 preserved.


#404 manual imported metadata flow started with pure model protocol boundary:
GitHeadObservation.parse validates exactversion1keys/layout/scope/status/reasons,
consistent symbolic/direct/unresolved/refusal fields, strict literalref/OID subset,
falseGitverification and unknown working/ahead/conflict. Duplicate/escapedkeys,
oversize/malformed/extra/contradictory/known-state assertions fail with fixed
private FormatException/no rawsource. No storage/HTTP/widgets/process imports.
Initial7modeltests PASS, log /tmp/asg404-imported-git-metadata-model-start.log;
format/diffcheck clean. Nativehost/controller/panel/asset/actualMac/IABwhere
applicable/broaderchecks/inventory/review/CI/merge remain PENDING. Read-only
researcher requested nativejob lifecycle/test matrix, no extra writer/claim.
No helper launched or apppermission/UI integrated in this start; sole task lease
active. No ownerrepo/runtime/model/nativeapp/install/cloud/deploy effects.


#404 manual metadata flow now freezes the validated model and host interface for
two disjoint tracks within ONE coherent futurePR (not dependent features):
GitMetadataReadRequest immutable root/python; GitMetadataHost supported/inspect/
cancel/dispose, owned cleanup including late startup before another job. Root
continues controller/view/asset/shareddocs; delegated nativehost writer may own
ONLY git_metadata_host_native.dart and git_metadata_host_test.dart in distinct
registeredWT. Placeholder native factory is unsupported until integrated, not
a product implementation or advertised capability. Both use frozen interface
handoff and depend only on verifiedhelperPR787. Stop/commit/release both before
union; root sole integration owner, max2writers. No model/runtime/ownerrepo effects.


#404 manual Git metadata UI/controller handoff: 21 focused model/controller/widget/architecture tests PASS; focused analysis clean. IAB disposable browser component fixture verified explicit confirmation then literal declared reference/OID with working tree, sync and conflicts unknown; real browser factory disabled as unsupported. Supplied fixture data only, no filesystem/process/model inference proof. Native writer stopped clean at6250dfb (two owned paths), 27 focused Flutter/33 Python helper tests and clean analysis reported; its actual disposable Mac helper smoke uses injected trusted asset bytes, not packaged bundle. Native claim released. UI handoff stops for union integration; full final checks/packaged asset/native build/fresh PR review/CI/merge remain pending. No owner runtime/model/stable app changes.


### #404 manual imported Git metadata — integrated implementation and review fixes

One coherent manual action is now integrated into the imported workspace, after
existing requirements/plan controls and approval limitations. It performs no read
on open and grants no source-write, Git, model or process authority from project
text. Explicit confirmation freezes selected folder plus saved existing absolute
Python; default relative python3/corrupt settings refuse without settings writes.
Pure strict version1 parser rejects duplicate/escaped keys, malformed/extra or
contradictory fields, oversized JSON and any verified/known Git-state assertion.
Displayed literal reference/OID are declarations only, never verified commit or
object state; workingtree/aheadbehind/conflicts remain unknown. Missing loose
reference remains unresolved, packed/indirected layouts unsupported. Web and
non-Mac factories remain unavailable, not platform acceptance.

Native service runs the trusted bundled command-free reader using resolved
configured Python outside canonical selected root, -I -S -B, no shell/PATH search
or inherited environment, owned private empty temp cwd outside root. Deadline
covers input/assets/temp/start/exit/pipeEOF; 4KiB stdout and stderr caps and any
stderr/nonzero/invalid payload fail privately. Captures late-start Process handle;
cancel/dispose share owned kill/reap/tempcleanup before another inspection. Only
owned live Process handles are signalled; no savedPID, owner runtime or Git
commands. Cleanup uncertainty blocks retries and preserves unexpected entries,
no recursive deletion. Prior reading retained visibly stale on failure/Stop;
controller suppresses late results and waits cleanup. This is containment-aware
metadata observation, not OSsandbox or atomic/authenticated repository proof.

Root UI and native tracks stopped/committed/released before union claim and
native6250dfb handoff integration. Full regression exposed initial panel placement
pushing existing approval disclaimer out of initial lazy viewport; moved panel
after all existing controls/limitations, affected20tests nowPASS. Read-only source
review found synchronous busy-listener Stop could precede dispatch; new regression
failed before fix (one unexpected host request), post-notification Stop/disposal
guard now prevents dispatch; controller8testsPASS. Source re-review no remaining
blocker, not finalremotePR review. Logs /tmp/asg404-git-metadata-{layout,stop-before,
stop-after}.log. These were unmerged integration defects, not owner incidents.

IAB supplied-data component fixture verified manual confirmation then declared
reference/OID plus unknown state, and actual browser-default factory disabled.
No filesystem/process/model accessed by that fixture. Native19host+7model+1
architecture27PASS and inherited33Python reported in stopped handoff, including
actual disposableMac helper smoke using existingPython and injected trustedsource
bytes. Asset packaging/finalfullchecks and isolatedMacbuild are separately checked
on integrated source; do not equate fixture with nativeUI or liveinference.
Full404/CE07/CE13, liveQwen and deferred400 remain OPEN; marketplace gate/F23-last
retained. No installs/downloads/stableapp replacement/owner runtime changes or
cloud/deployment. Final exactPRreview/requiredCI/protectedmerge remain pending.


#404 integrated final local checks after both fixes: fullFlutter2320PASS with13
explicit skips, format572unchanged, analyzer clean, web/Wasm dryrun built, isolated
normal Mac debug build succeeded with disposable derived output and validation
bundleID (no install/launch/stable replacement). Python helper33/coordinator20/
product32/inventory9PASS. Logs /tmp/asg404-git-metadata-{full3,format,analyze,web,
mac-build3,python,coordinator,product,inventory}.log. Mac and web packaged helper
bytes exactly match reviewed source SHA256
c6252d5d47f6305f6d098d60b2cbe659d4d1199d19cc60ffec68ff6f4aec3be0.
Actual isolatedPython invocation of the builtMac packaged helper on a disposable
looseHEAD/ref fixture PASS, no stderr, root bytes unchanged, tempfixture removed.
Receipt /tmp/asg404-git-metadata-packaging-receipt.json. This verifies packaging
and controlled helper execution, not nativeUI or liveinference/allplatform flow.
Final exactremotePRreview/requiredCI/protectedmerge pending; full404 remainsOPEN.


### 2026-11-20 — #404 manual metadata merged; imported-manifest boundary investigation started

PR788 protected expected-head squash merge
d9d8299635ab8a41524709b2bf618bff9a92e2f0 verified through plugin currentmain,
mergedPR and fetched treef08c456fb7afd20e71c861555276fe89d66bfb3d, identical tested
locala3c050381d0d65f7357a27dacb9097bf9c0a11f1. Exactreview remote30308b608cb17d04b19a4cb55ed5878ee594adc3
/base6090d539b9bcecc59387aa78fcb845e01ef8b480 no blocker, threads empty.
CI44707141760 Flutter136189452318/Python136189452581 every required/post step
SUCCESS, including browser transport/storage, independent generated project and
33command-free helper cases onLinux. Local2320FlutterPASS13skips, cleanformat/
analyze/web/isolatedMacbuild and packaging/disposableMachelper evidence retained.
Bounded manual metadata increment Done; full404 remainsOPEN, no nativeUI/live
inference/allplatform claim. Coordinator merged/outcome recorded, integration
and writer claim released. Ownerdirty checkout and stableapp/processes preserved.
09:02:46UTC /health and /v1/models both unavailableURLError; generation0, owner
runtime left running/untouched if present. LiveQwen acceptance stayspending.

Immediately claimed404-project-inspection-file-boundary-investigation in reused
registeredissueWT/currentmain under existing404/F20, solewriter. Three docs only;
no new issue/backlog. Observable outcome: establish current manifest containment
limits before broader source/instruction context, with controlled Mac evidence and
a bounded remedy proposal. Read ProjectInspector/model/imported-plancontext and
existing symbolic-link tests. Inspector uses nofollow type checks then pathname
File.open/read, but no single-link or opened-descriptor identity observation.
Imported plan context currently contains root/package/sdk/runners/requirements,
not arbitrary repository source/instructions. No new source reading enabled.

Initial actual existingDart importer probe on source d9d8299,09:12:28UTC: regular
manifest accepted(linkcount1), same valid manifest hard-linked from a separate
controlled fixture location accepted(linkcount2), symbolic-link control rejected.
All fixture bytes unchanged; owned temp fixture removed. ExistingtrustedDart only,
no project commands/model/network/ownerrepo or secrets. Receipt
/tmp/asg404-project-inspection-boundary-receipt.json SHA256
117d27fa2edc1668da401e06c8ebbb355bea592e2c6a1f2e057f17cefb0ff718; privateprobe
/tmp/asg404-project-inspection-boundary-probe.dart SHA256
b89f1e74c91525149228c002b4e4c5fb8b636e767149b03fe196146a090cbc3a.
This demonstrates hard-link alias admission, not outside owner data access or
sourceexecution/approval escalation. Path check/open race is a source inference,
not a measured race result; no atomic/OSsandbox guarantee is claimed.

Next investigation step: compare currentDart file primitives and the reviewed
descriptor helper boundary, identify the smallest verifiable containment remedy
and its regression cases without expanding execution permissions. Investigation
remains in progress; focused existinginspector validation, final review/CI/merge
stillpending. Solelease retained. Marketplace gate/F23-last/deferred400 preserved.


#404 imported-manifest boundary start checkpoint: existing ProjectInspector
focused suite5PASS (regular/invalid/missing/oversize/linked/unsupported cases),
log /tmp/asg404-project-inspection-boundary-focused.log. Together with three
disposable actual importer controls, confirms current static symlink rejection
and hard-link alias admission. No race execution proof. Three-doc investigation
checkpoint committed; sole currentclaim valid, no integration lock/publication.
Next: smallest containment remedy and deterministic regression design; full404/
liveQwen/deferred400 remain open.


### #404 imported-manifest containment investigation — measured conclusion

Installed Dart SDK public FileStat exposes times/type/mode/size, not device/inode/
linkcount; RandomAccessFile has no public fstat/dirfd/openat/nofollow interface.
Current ProjectInspector requires nofollow path types, then File.open follows
the pathname. Adding File.stat before/after or resolveSymbolicLinks cannot by
itself establish that the opened descriptor is the validated object. Public
File locks also do not prevent an uncooperative pathname replacement. No new
FFI/native ABI assumptions, package installs or project execution were introduced.

09:16:34UTC deterministic controlled IOOverrides intervention on unchanged
source d9d8299635ab8a41524709b2bf618bff9a92e2f0: replace the regular selected
pubspec.yaml with a symlink immediately at final File.open (after importer type
checks). Existing importer/actual filesystem read returned outside_control from
a separately located controlled valid manifest, rather than inside_control from
the validated original. Held original, outside fixture and inert main bytes
unchanged; all owned tempfixture removed. This is an instrumented check/open
replacement demonstration, not unassisted concurrency/attack likelihood, secret
exfiltration or sourceexecution. Initial test-hook run rejected its own rename
return File constructor; corrected fixture also delegates that known held path.
No product change was needed for the successful demonstration.

Private probe /tmp/asg404-project-inspection-replacement-probe.dart SHA256
6ab0c7496e44550a75516759fd4fa3f347004002d23ff491f2f59c29d256d00f; receipt
/tmp/asg404-project-inspection-replacement-receipt.json SHA256
d57a02ed8de5ab5143cfa35f4614a9bf46c6f0d50a71ceedd24a818ab97a7bd0.
Together with regular/hardlink/symlink controls and existing5PASS, current boundary
is static symbolic-link rejection, not descriptor-contained stable source reads.
Imported planning currently records only root/package/sdk/runners/requirements;
this finding grants no broader repository access or executable tool authority.

Concrete next F20 prerequisite under existing404: implement a command-free
POSIX descriptor-based project-metadata reader with deterministic containment
fixtures, before integrating it into the import action. Bound canonical root,
regular single-link pubspec<=64KiB, lib/main existence and fixed runner names;
anchor all components/names with nofollow descriptors, validate pre/opened/post/
named identities and missing-entry changes, close every handle and emit bounded
versioned private JSON. No source file bodies beyond the manifest, recursive
scan, Git/config/hooks/project commands/network/writes or automatic retries.
Keep manifest schema parsing in Dart or return bounded content for the existing
parser; stdlib helper must not require PyYAML/site packages. Test leaf/ancestor
replacement, hardlinks/FIFO/mutation/oversize/unchangedbytes/FDcleanup and controls.
Treat root/manifest/source/runner stability as one read set, not independent
stat-then-read checks. Descriptor containment still is not atomic repository
snapshot, authenticated source or a general OSsandbox.

Future app integration needs explicit reviewed interpreter/asset/process/consent
contract and owned deadline/Stop cleanup; do not silently add interpreter setup
or a dependency to existing cross-platform import, or advertise support until
that integration is verified. Preserve saved folders, unrelated records, last
working outputs and separate plan/source-write approvals. This investigation
changes only three docs; no import behavior is fixed/enabled by this PR. Final
exactPRreview/requiredCI/verifiedmerge pending. Full404/liveQwen/deferred400 open,
marketplace gate/F23-last preserved. No independent second writer task is ready.


### 2026-11-20 — #404 containment investigation merged; descriptor reader started

PR789 protected expected-head squash03dde5cefe6afc4334ddb94f87eb5068f97e3bcf
verified through plugin main/mergedPR and fetched tree
e0d1ec349f185dc986d6be5bf94a3832fb580dae, identical reviewed local9ad9606453de7b5ba5136df9194d9f19ae922b3a.
Freshreview remote0fe75df8e579bebb48ffd8f5b1cd16c06a4757a4/base d9d8299 no
blocker, threads empty. CI44709627694 Python136197725946/Flutter136197726132
every required/post step SUCCESS. Three-doc investigation Done: measured regular/
hardlink/symlink controls and controlled final-open replacement, publicDart API
limits, explicit descriptor-reader prerequisite. No importer behavior fixed by
that merge; full404 stillOPEN. Coordinator merged/outcome recorded, integration
and claim released. Ownerdirty checkout/processes/stableapp preserved.

Immediately claimed404-descriptor-project-metadata-reader under existing404/F20
in reused registeredissueWT/currentmain, solewriter. Scope two new Python files,
existingPythonCI step and three docs. One internal safety prerequisite, not app
integration or expanded repository access. Fixed --root, version1 exact8keys
version/scope/status/reason/manifest_base64/included_runners/main_present/
source_verified. Scope project-metadata-files, source_verified=false always.
Success transports <=64KiB rawmanifest as base64, main_presenttrue and fixed
runnernames; refusal nullmanifest/nullmain/emptyrunners+fixed private reason.
Output<=128KiB; base64 is not YAMLvalidation/sourceauthentication.

Initial tools/project_metadata.py anchors canonicalroot/components/lib/runners
with POSIXnofollow directory descriptors, regularsinglelink pubspec boundedread,
regularsinglelink main existence without bodyread, stable held/named readset and
missingrunner checks. Reviewed Git-reader descriptor patterns adapted locally,
without importing Git logic or changing its verified implementation. No recursive
scan/listdir/Git/config/hooks/YAMLpackages/subprocess/network/write. Parentmust
enforce processdeadline; no atomicrepo/OSsandbox claim. App import remains unchanged
until separately reviewed consent/interpreter/asset/process integration.

Initial10disposableMac tests PASS: rawmanifest/fixedrunners, exact65536binarybytes
base64roundtrip87384bytes, oversizedpre-readrefusal, missingrequiredentries, hardlink
refusal beforecontentread, symlink/FIFOrefusal, onlymanifestbodyread+allFDclose,
stat-open replacement refusal with separateoutside sentinel unchanged, missing
runnerappearance beforefinalvalidation, actualPython-I-S-BCLI fixed8keyJSON.
Log /tmp/asg404-project-metadata-start.log. This is start evidence only: expanded
ancestor/main/runner replacement/mutation/private-error/FDfailure cases, CI
registration, broaderrequiredchecks/freshreview/protectedmerge remain pending.
Read-only design reviewer supplied cases but wrote/executed nothing. No second
independent writer task ready. Solelease remainsactive; full404/liveQwen/deferred
400 open, marketplace gate/F23-last retained. No installs/modeldownloads/runtime
changes/stableapp replacement/cloud/deployment.


### #404 descriptor project-metadata reader — final local implementation evidence

Standalone stdlib tools/project_metadata.py implements fixed --root/version1
project-metadata-files JSON with exact8keys, source_verified=false and no root/OS
error echo. Manifest bytes<=65536 are canonicalbase64transport, not YAML validation
or source verification; output<=128KiB. Included fixed runner directories are
not tested platform support. Main must be an openable regular single-link file,
metadata only: no main/source body read. Refusals erase manifest/runners/main
payload rather than mixing partial observations. No app/asset/caller integration
or interpreter setup changes are included; existing importer behavior is unchanged.

Canonical root/ancestors/lib/runners use anchored nofollow directory descriptors;
manifest/main use nofollowstat, regularsinglelink policy, nonblock/nofollowopen
and matching openedidentity before any contentread. Manifest boundedmax+1read,
size/signature checks; final held/named file and directory identities plus stable
missingrunner observations cover one readset. All owned handles close in finally.
No Git/config/hooks/sourcebodies beyondmanifest/listdir/recursive scan/YAMLpackages/
subprocess/network/writes or automaticretry. Still best-effort mutation detection,
not atomicrepo/authentication/OSsandbox against hostile mounts/writers. Filesystem
syscalls may block: a future caller needs owned processdeadline/Stop/reap cleanup.

29focusedMac tests PASS: fixedrunner/rawmanifest controls, exact64KiB binary
base64roundtrip and oversizedpre-read refusal; requiredmissing/unsupportedhost/
invalidroots; root/ancestor/lib/runner links; mainhardlink/link and unreadablemain
policy; pubspecstat-open link/disappearance/hardlink/grow/FIFO swaps; midread
truncate/same-length/grow; finalmanifest/main/root/lib/runner replacement/removal;
missingrunnerappeared/finalstaterror/permission-not-absent/privateerrors; only
manifestbodyread/no scans/highlevelopen/processes; FDcounts success/readerror/
representativerefusals; actualPython-I-S-BCLI fixed8keyJSON and privateinvalidargs.
Outside sentinels in separateownedtempfixtures retained unchanged. Initialexpanded
fixture collided with existinglib directory; corrected test-only nestedcase names,
then29PASS. No product failure was hidden or converted to skip.

Read-only implementation/test/workflow source review found no blocker, no edits
or executed-test claim. Mainpolicy clarified; finalvalidation cannot detect every
mutation after its last check, consistent with explicit non-atomic limit. Existing
PythonCI job adds only deterministic suite step; permissions/pinnedactions/checks
unchanged. Required remoteCI must show29cases ACTIVE Linux, not merelygreen/skipped.

Local29new/33Githelper/20coordinator/32product/9inventoryPASS; fullFlutter2320PASS
13explicit skips, format572unchanged, analyzer clean and web/Wasm dryrun build
succeeded. Logs /tmp/asg404-project-metadata-{final-focused,git-regression,coordinator,
product,inventory,format,analyze,full,web}.log. This is helper/CLI and regression
evidence, not real app import repair, liveinference or unavailableplatform proof.
Final exactPRreview/allrequiredCI/protectedmerge pending. Full404/liveQwen/deferred
400 OPEN, marketplace gate/F23-last retained. No ownerrepo/runtime/model/stableapp/
install/download/cloud/deployment effects.


### 2026-11-20 — #404 descriptor reader merged; confirmed contained import started

PR790 protected expected-head squashff2872e107846789fe2378b06d00bcdfd1ecdd6d
verified plugin currentmain/mergedPR plus fetched tree
f6fbf83ad9135a800d0ac747402bac427d938739 identical tested localbbc17619d84af2125c958a1d0bbb47cc7d769eb7.
Freshreview remotec9d44afb0c4e2715262e60ae386486bc4a7dcf9f/base03dde5c no
blocker, threads empty. CI44712328426 Python136206846367/Flutter136206846992
everyrequired/post step SUCCESS; new29cases ACTIVE Linux no skips. Mac29+33Git/
20coordinator/32product/9inventory/fullFlutter2320PASS13skips/format/analyze/web
retained as datedmatching evidence. Boundedstandalone reader Done, not appimport
fix or liveinference/platform acceptance. Full404 remainsOPEN. Coordinator
merged/outcome recorded; integration/writer claim released. Ownerdirty checkout,
stableapp/runtime/processes and lastworking outputs preserved.

Immediately claimed404-confirmed-contained-project-import under existing404/F20,
one coherent futurePR for choose/reopen/open-workspace consent, strictresponse
projection, ownedhelper process/Stop cleanup and savedfolder preservation. No
newissue. Legacy path-based inspector must be retired/failclosed before completion;
no silent fallback. Existing savedfolder/settings formats and separateplan/write/
execution approvals remain. No automaticinstall/runtime/model setup. Web and
nonverifiedhosts unavailable honestly, deferred400/marketplace gate/F23-last kept.

Initial pure ProjectMetadataObservation parser requires exactversion1/scope/8keys,
false source_verified, strictknownstatuses/reasons, no partialrefusalpayload,
orderedunique fixedrunners, canonicalbase64+decoded64KiB/rawJSON128KiB bounds.
Immutablemanifest/runners; pure private-error UTF8/YAML projection preserves
existing Fluttermanifest requirements with no IO/authority. Immutable
ProjectMetadataReadRequest root/python is one-action controller snapshot, not
execution consent.9focusedmodel+architecture testsPASS,6fileanalysisclean, format
clean; initialbrace-style finding fixed. Logs /tmp/asg404-contained-import-model-
{tests,analyze,format}.log. App flows, native execution/assets/controller/consent
UI/fullchecks/build/IAB/exactPRreview/requiredCI/merge remain pending.

Frozenhost interface ProjectMetadataHost supported/inspect(request)->observation/
cancel/dispose now committed alongside model; cancel settles ownedcleanup incl
latestart beforeanotherjob. Factories/stubs remain unsupported baseline until
nativehost integration; notadvertisedproductbehavior. Two disjoint tracks within
ONE coherent parentPR can now use this local frozeninterface, depending only on
verified790/788: rootUI/controller/model/asset/sharedrecords, nativewriter ONLY
project_metadata_host_native.dart and project_metadata_host_test.dart. Stop/
commit/release both before unionintegration. Root soleintegrationowner; max2writers,
no competingmodel/nativebuild/artifact work. No ownerrepo/model/runtime effects.


#404 contained import tracks admitted after clean frozenbaselinee4e033e7fbd2a6e6318e74c6d8c1131f76ccbd96
/tree7b12149359eae378566b8adb50c628af7d957c33: parentclaim released; root claims
404-contained-project-import-ui (all parentpaths EXCEPT nativehost/test), delegated
404-contained-project-metadata-native-host claims only those2paths in separate
clean registeredWT/directissuebranch on agreedbaseline. Nativewriter independently
verified currenthelpermainff2872e/ancestor through plugin+safe fetch, privatelease
valid3600sec. No integrationlock or PRpublication for incomplete appfeature.
Frozen APIs unchanged; root handles consent/controller/legacyinspector retirement/
assets/sharedrecords, nativewriter handles owned128KiBtransport/lifecycle fixtures.
Both must stop/commit/release before union. Nativeimplementation nowunderway;
model9tests/analysisclean are initial evidence only, appintegration not complete.


#404 confirmed import UI/controller handoff checkpoint (incomplete): controller
choose/reopen/open now take view-owned confirmation callback freezing root/python,
private settings validation, stale retained findings, Stop/disposal/pre-dispatch
guards and ownedcleanup wait. Strict inspectoradapter has no direct File.open;
legacy nativefile is compatibility export, stub unavailable; view renders consent
and blocks stale navigation; asset added. Updated existing tests and new consent/
cleanup tests. Nativewriter stopped clean atd30478dd2fa4e8b32a0dc714b0817b3c235403d6
(twoownedpaths),33Flutter/29helperPASS/analysisclean reported, ownclaimreleased.

First combined UIcompile exposed additional productioncaller in ImportedPlanController
that auto-invoked the old inspector on plan load/save/approval. No tests claimed
passing for this checkpoint. Root must expand union scope BEFORE editing that
controller/view/workspace/tests: use explicitly confirmed workspace metadata
snapshot for planning (apprecords only), label captured planningcontext and require
explicit reinspection for disk refresh, never hiddenhelper launch or pathname
fallback. Existing save/order/contextguards remain. RootUIstops/commits/releases
for union; no publication until this discovered path and all regressions pass.


### #404 confirmed contained import — final integrated behavior and checks

RootUI stopped/committed before revisedunionclaim; nativewriter stopped/released
2pathhandoffd30478dd2fa4e8b32a0dc714b0817b3c235403d6 integrated without changing
frozenmodel/host API. Union scope explicitly added discovered planning caller
before edits. DefaultProjectInspector now projects a strict helper response and
requires explicitPython; legacy native compatibilityexport has no pathname reads,
stubfailsclosed. No current production ProjectInspector caller falls back to
File.open/pubspec path reads.

Choose/reopen/open-workspace use view-owned confirmation with frozen root and
existing configured absolutePython, no read on screen open or automaticsettings/
install/model changes. NativeMac helper resolves interpreter outside selectedroot,
private outside temp/cwd, -I-S-B, no inheritedenv/shell/PATH search. Stdout128KiB/
stderr4KiB caps, any stderr/nonzero/schema/UTF8failureprivate; deadline covers
assets/temp/start/exit/EOF; capturedlateProcess cleanup/kill/reap/tempdelete blocks
nextjob, uncertaincleanupsticky. Web/otherunverifiedhosts unavailable honestly.

Controller guards synchronousbusy/confirmation Stop/disposal beforedispatch, late
picker/consent/results, concurrentchooser/reopen/save and finalbusy-notification
disposal before navigation. Stop does not pretend to close nativefolderpicker;
usercloses pendingchooser/dialog tofinish, busy excludes anotherlaunch. Previous
findings retained visiblystale onfailure/Stop, disabledsave/open; savedfolderkeys/
JSON and storage ordering retained. Workspace opens only fresh matching success.

ImportedPlanController default now consumes workspace’s immutable explicitly
confirmed metadata snapshot and current apprecords only. Planload/save/approval
never implicitly refreshesdisk/helper or fallsback to old inspector. Missing or
wrongroot snapshot failsclosed; captured-contextlabel tells users to explicitly
reinspect for disk refresh. Existing plan save/context/invalidation guards and
separate source-write/execute approval limits remain; no sourceediting/preview or
verified Git/source/platform authority is enabled. No persistenceformatmigration.

Prepublication failures corrected: initialcompile exposed automaticplanningread;
scope expanded then replaced by snapshot. Busyspinner whilewaitingconsent caused
pumpAndSettletimeout; spinner nowrepresents work only. Widgetscroll checks now
waitlayout before taps; 320x800/textscale2 reproduced actualdialogRenderFlex64px
overflow afterfixing lazylisttestscroll, fixed by scrollabletitle/content. Analysis
brace-style infos fixed. These were unmerged integration findings, not ownerapp
incidents. Read-only combinedreview no remainingblocker, not executed-testclaim.

80focusedcombined checks PASS before additionalrealpackagedadapter case. Final
local fullFlutter2367PASS13explicit skips, format580unchanged, analyzer clean;
normalmain web/Wasm dryrun and isolatednormalMacdebugbuild(customvalidationID,
noinstall/launch/stablereplacement) pass. Pythonprojecthelper29/Githelper33/
coordinator20/product32/inventory9PASS. Logs /tmp/asg404-contained-import-
{combined-focused3,full-final,format-final,analyze-final2,web-final,mac-build-final,
project-helper,git-helper,coordinator,product-final,inventory-final}.log.

Actualdefaultpackagedasset ProjectInspector Macservice test5PASS includes strict
projection of regularfixture plus hardlink/symlinkaliasrefusal with separateowned
outside sentinel/main unchanged, knownexistingFrameworkPython, no projectcommands.
Log /tmp/asg404-contained-import-packaged-adapter.log. Mac/webpackaged helper bytes
match reviewedsource SHA25609c3370c5e43cabf2cca9a7f26db1a09aaffff6e8a6e5edee0a259f01df10bc7;
actual builtMacasset isolatedPythonCLI ondisposableFlutterfixture PASS, unchanged
bytes; /tmp/asg404-contained-import-packaging-receipt.json.

IAB supplied-data fixture verified cancel/explicitroot+interpreterconfirmation/
findings/save-reference/reconfirm-before-workspace/open/snapshotplan screen.
Browserdefaulthelper supported=false visiblylabelled; fixture usedcontrolledpicker/
memoryrecords/fakehost, no filesystem/process/model access. NativeUI fixture
(customcom.arsinha.asg.containedimportuifixture/isolatedderivedfolder) built, but
computer-use getApp failed with expiredcontinuation before returnedUIstate; fresh
inventory/processcheck foundnofixtureprocess/eventlog. Controlledselectedfixture
bytes unchanged. NativeUI interaction remains UNVERIFIED; do not convert build,
Macservice test or IABfixture into nativeUI/ownerfolderchooser/liveinference proof.
UIreceipt /tmp/asg404-contained-import-ui-receipt.json SHA256
85eeec7c9fad55c31010ba447b78e1b277ba4e217c1180d92f2c99e0c3c66180; recordedproduct
sourcehashes still match. Ownedlocalhostpreviewserverstopped; ownerprocesses,
stableapp/config/data untouched. Retaineddisposablefixture/bundles are notdeployed.

Helper observes bounded point-in-time metadata, not atomic/authenticatedrepo or
OSsandbox; interpreter must be outside selectedfolder, no silentfallback/install.
Full404/liveQwen/unavailableplatform400 OPEN, marketplacegate/F23-last retained.
Final exactremotePRreview/allrequiredCI/verifiedmerge remain mandatory.


### 2026-11-20 — #404 confirmed import merged; instruction-context investigation started

PR #791 merged as 5f4077f4354baaccc907b4da2196da3f367366d7 after the fresh
review of remote24397985d908f8fd9af73d9763b4ae6dcdbd1bdb against ff2872e.
Required CI44721642325: Flutter136238603738 and Python136238604011, every
required and post step SUCCESS. Plugin main/merged PR and fetched merged tree
 e4eb05644523bb636e35ba4f363247a8d4628bde match tested local42e744a.
Issue #404 remains OPEN. Coordinator merge/outcome recorded; integration and
completed claim released. Delivered explicit contained metadata import/reopen,
owned helper lifecycle and captured planning context. Local2367FlutterPASS with
13 explicit skips, analysis/format/web/isolatedMacbuild pass. Actual packaged Mac
service and supplied-data IAB flow are separate evidence; native UI launch failed
before reporting state and remains UNVERIFIED. No live inference claim.

Immediately claimed 404-imported-instruction-context-boundary in the registered
issue worktree on verified main, sole writer, under existing F20/#404 bounded
source/instruction acceptance. Three-doc scope only: requirements, progress and
AGENT_ENGINE architecture. This is a prerequisite investigation, not enabled
repository instruction loading or another backlog. No independent second task
is ready. Owner dirty checkout/processes and stable application remain preserved.

Actual ImportedPlanStore.context serializes exactly root/package/dartSdk/runners/
requirements from the confirmed inspection and saved application records. There
is no imported AGENTS.md/README.md reader. A disposable Flutter probe created
only owned temporary instruction documents and memory records, saved/approved a
captured plan, changed those documents, and found identical context and retained
approval; changing captured SDK changed context. Probe plus existing planning
regressions:13PASS, /tmp/asg404-instruction-context-start.log. Receipt:
/tmp/asg404-instruction-context-start-receipt.json. No model request, owner-project
content read, project command, installation or selected-owner-file write occurred.
Omission is a known missing capability, not a promise that current approval binds
to disk instructions. Requirements changes already invalidate captured plans.

Next work in this active investigation: define and review a bounded document
readset and provenance/authority contract before implementation. Explicit selected
files, per-file/aggregate byte limits, strict encoding, content hashes and root/
relative-path identities must be covered by fresh consent and change detection.
Reject links/special files/retargeting, malformed or oversized payloads privately;
retain last working outputs and require fresh context review when any included
input changes. No recursive discovery or silent model sharing. Repository text
is untrusted data: it never grants tools, commands, installation, network or source
writes, and cannot supersede owner policy. Reuse the descriptor/owned-process
boundary only after evaluating its document-specific readset and failure cases.
No reader/schema implementation is enabled by this start record; final contract,
required checks, fresh PR review and verified merge remain pending. Full F20,
live Qwen and unavailable-platform #400 acceptance remain open; marketplace gate
and F23-last remain unchanged.


### #404 imported instruction context — bounded prerequisite contract

Investigation outcome: existing imported planning does not read repository
instruction documents. The 13-case probe/regression evidence above establishes
omission and snapshot semantics only. Existing advisory review prompts already
label evidence untrusted, and RepairRequestContext captures fixed application
record identities; neither is a repository document loader or disk readset.
Do not route repository prose through the application's trusted instruction or
permission channels. Full F20 remains unchecked.

The next eligible implementation under this same umbrella is a command-free
instruction-document observation helper, followed by a separately reviewed app
integration. The helper contract is deliberately bounded:

- Explicit canonical selected root, with a nonempty user-selected subset of
  root-relative `AGENTS.md` and `README.md` only; canonical fixed order, no repeated
  paths, nested discovery, includes, URL fetches, globbing, submodules or Git calls.
  A missing selected file is a refusal, not silently omitted context. Unselected
  documents are never opened. Reading project source remains separate acceptance.
- Maximum 32 KiB raw bytes per selected document, 64 KiB aggregate, 128 KiB total
  response. These are byte bounds, not model-token capacity claims. Require strict
  UTF-8 without NUL; retain exact bytes for SHA-256 and base64 transport. No YAML,
  Markdown directives, shell fragments, links or embedded instructions execute.
- Versioned fixed-key response with a literal scope, ordered selected readset,
  status/private reason and `source_verified=false`. Each successful entry binds
  exact relative path, byte length, SHA-256 and canonical base64. Reject unknown,
  duplicate/escaped-duplicate JSON keys, unsupported versions, inconsistent sizes,
  hashes, paths and encodings. A refusal contains no document body or partial
  successful entries. Root identity is frozen in the caller request; no absolute
  filesystem paths or OS exception text need be echoed by the helper.
- Anchor root and ancestors with nofollow descriptors, then only single-link
  regular selected entries with before/open/after/final held-and-named identity
  checks, bounded reads and complete handle cleanup. Refuse links, hardlinks,
  special files, permission failures and observed mutations; preserve outside
  sentinel bytes in adversarial fixtures. Descriptor checks are best-effort
  mutation detection, not atomic repository authentication or an OS sandbox.
- App integration must separately freeze root, selected paths and an existing
  absolute interpreter resolving outside the root; preview those identities
  before read consent. Use a packaged reviewed helper, isolated launch, deadline,
  bounded output, strict response validation and owned Stop/late-start/reap/cleanup
  semantics. No auto-install, fallback runtime, repository command or selected
  file write. Browsers/unverified hosts refuse through an explicit capability.
- Observation consent permits reading only. A separate preview/model action must
  identify the exact captured text and configured destination. No automatic model
  send or local-to-cloud fallback; F23 external data-sharing remains gated. Text
  stays an attributed untrusted-data block, never a system instruction, permission
  grant, command, tool request or schedule. Prompt wording alone is not enforcement:
  deterministic operation/path/resource policies continue to control all effects.
- Any later plan context must bind observation version, selected root/readset,
  document path/size/digest and captured requirements/metadata. A changed readset,
  byte digest, root, requirements or relevant model/operation policy invalidates
  affected review. Revalidate with fresh explicit read before claiming current
  disk state; saved snapshots remain historical and cannot authorize execution.
  Malformed/oversized/refused/cancelled reads retain last working context as stale,
  never silently replace it with an empty successful context or revive approval.

Acceptance before app integration: deterministic boundary tests on this Mac and
active supported POSIX CI for exact byte limits, two-file aggregate, invalid UTF-8,
NUL, missing/linked/hardlinked/FIFO entries, root/ancestor/entry replacement,
mid-read mutations, final readset changes, private error responses, no unselected
body read, no recursion/process/network/write, FD cleanup and isolated CLI output.
Typed parsing and lifecycle integration need their own strict/failure/disposal
regressions and honest service/UI evidence. This document implements none of those
future behaviors. Native UI failure, live Qwen identity and deferred #400 remain
separate acceptance. No model runtime, owner process or stable app was changed.


Protocol decision for that prerequisite: exactly seven top-level members
`version`, `scope`, `status`, `reason`, `selected_paths`, `documents`,
`source_verified`; version integer1, scope `project-instruction-documents`,
source_verified literal false. Request selection uses the fixed ordered allowlist
above; success must echo that exact selection and return the same ordered paths.
Each document has exactly `path`, `byte_length`, `sha256`, `content_base64`.
SHA-256 is lowercase 64-character hex of exact decoded bytes, with no whitespace,
newline or Unicode normalization; strict UTF-8 decoding occurs after byte/hash
validation. Reject NUL. Empty regular documents may succeed and remain attributed;
an empty selection does not. Failed observations retain only safe fixed selection
names, documents=[], and a fixed allowlisted private reason. Observed status uses
reason=null; other statuses are invalid/unsupported/changed/unavailable. No raw
exception/message/extensions or privilege field is accepted. This is a proposed
wire contract, not an implemented or authenticated source snapshot.


Final local investigation checks:13focusedPASS, fullFlutter2367PASS with13explicit
skips, format580unchanged, analyzer clean, web/Wasm build succeeded; product32 and
inventory9 PASS. Logs /tmp/asg404-instruction-context-{final-focused,full,format,
analyze,web,product,inventory}.log. No product source, helper, manifest, workflow
or persistence schema changed. Three-doc exact PR review and required remote CI
remain mandatory; this investigation is not marked Done before verified merge.


### 2026-11-20 — #404 instruction-context investigation merged; reader started

PR792 protected expected-head merge277afee6f8dfd5d7706ef4a3e240822132a7677c
verified through plugin main/merged PR and fetched tree
5ec4a379148c30288e8a12beaf5cfc8e976c7b9d, matching tested local a1355b4.
Fresh exact3doc review remote44f382d54c09e92b6cab248c855ff76a2ea35b0a/base5f4077f
found no blocker; threads empty. Required CI44723877372 Flutter136246291177 and
Python136246291513 every required/post step SUCCESS. Bounded investigation Done:
measured current omission and fixed document provenance/authority contract, no
reader enabled by that merge. Full404OPEN. Coordinator merge/outcome recorded,
integration/claim released. Owner dirty main/processes/stable application retained.

Immediately claimed404-contained-instruction-document-reader under existingF20,
sole writer in registered issue worktree/current verified main, with prerequisite
merge evidence. Scope standalone Python reader/test, eventual deterministic CI
step and these three shared docs. No independent second ready task. Initial
project_instruction_documents.py adapts the reviewed nofollow descriptor pattern
into the seven-key version1 project-instruction-documents response. Fixed explicit
root AGENTS.md/README.md selection only, canonical order, 32KiB/file and64KiB total,
128KiB output; strict UTF8/noNUL, exact bytes/length/SHA256/base64. Refusal drops all
partial documents; source_verified=false. No app/asset/typed caller/model wiring.

Initial10Mac disposable tests PASS: fixed keys/exact bytes/hash, two exact file
limits/emptydocument, oversizedpre-read refusal, malformedUTF8/NUL discards both,
invalid/duplicate/reversed/traversal selection noopen, onlyselectedbodyread,
missing/symlink/hardlink refusal, controlled stat-open substitution without outside
read or sentinel mutation, finalreadsetmutation discardsboth, actualPython-I-S-B
CLI and privateinvalidargs. Log /tmp/asg404-instruction-reader-start.log. This is
start evidence only: expanded ancestor/root/FIFO/midread/final identity/error/FD
cleanup cases, CI registration, full regression checks/freshreview/verifiedmerge
remain pending. Deadline/owned process lifecycle belongs to later app integration;
helper is neither atomic repository authentication nor an OS sandbox. No inference,
model/runtime/install/sourcewrite/stableapp/cloud/deployment effects. FullF20/live
Qwen/deferred400 remainopen; marketplacegate and F23-last retained.


### #404 contained instruction documents — final implementation evidence

Standalone stdlib project_instruction_documents.py observes only an explicit
nonempty ordered subset of root AGENTS.md/README.md, never discovering includes,
project source, instructions or links. Selection is frozen before filesystem work.
Version1 project-instruction-documents response has exact seven top-level keys;
each successful entry binds path/byte_length/SHA256/canonicalbase64 of exactbytes.
32KiB/file,64KiB aggregate,128KiB completeCLIoutput, strictUTF8/noNUL; BOM/Unicode/
CRLF preserved without normalization. Emptyregular documents are valid, empty or
invalid selection is not. Refusals erase all documentpayload, use fixedprivate
reasons and source_verified=false. No echoed roots/OSerrors or textauthority.

The reviewed descriptor pattern is adapted as a standalone helper, without a
project-local module import that could load repository code. Canonicalroot and
ancestors nofollow anchored; selected single-link regularfiles have matching
before/open/after/final held-and-named signatures, bounded reads and finally
cleanup. Root/ancestor/entry replacement and observedmutation refuse. No arbitrary
scan/Git/config/hooks/subprocess/network/selectedfilewrite/model. CLI fixed
--root ROOT --file AGENTS.md [--file README.md], or onlyselectedREADME, no shell.
Not atomic authentication/OSsandbox; filesystem syscall blocking requires future
caller-owned deadline/Stop/reap. No app asset/caller/typed parsing/UI/model sharing
or stored-context schema integration is enabled. Existing import behavior remains.

25focusedMac disposable tests PASS: exactkeys/path/byte/hash/base64, both32KiB
limits/emptytext, oversizedpreread, malformedUTF8/NUL and secondmissing/oversize
partialpayload erasure; invalid/duplicate/reversed/traversal/no-selection refusal
beforeopen; onlyselectedbodyread; root/ancestor symlinks; selectedsymlink/hardlink/
FIFO and stat-open FIFO/link/disappearance/growth; midread truncate/same-size/growth;
finalsamebytes replacement/removal/root/ancestor replacement; privatepermission/
read/finalstatfailure; ownedFDcleanup success/readfailure; noscan/highlevelopen/
process/network/write; unsupportedhost/syscalls; exact BOM/Unicode/CRLF; mutable
selection staysfrozen; actualisolatedPython-I-S-BCLI, bothfulldocuments128KiBbound,
privateinvalidargs. Outside owned sentinel remainsunchanged in controlledrace.
Log /tmp/asg404-instruction-reader-final-focused.log. This does not claim every
possible filesystem race is detectable. Readsetfreeze fixed during localreview;
no ownerincident or escapeddefect claim. LinuxCI must execute25cases actively,
not merelyreportgreen withsuite skipped. Existing Python job gains only this
stdlibsuite step; pinnedactions/permissions/protection unchanged. FullF20/liveQwen/
unavailableplatform400 remainopen, marketplacegate/F23-last preserved.


Final local checks:25instruction-reader/29project-reader/33Git-reader/20coordinator/
32product/9inventory tests PASS; fullFlutter2367PASS13explicit skips, format580
unchanged, analyzer clean and webbuild successful. Logs /tmp/asg404-instruction-
reader-{final-focused,project-regression,git-regression,coordinator,product,
inventory,format,analyze,full,web}.log. No live model request or app behavior change.
Final exact PR review, required CI with active Linux reader suite and verified
protected merge remain mandatory. Full404 and deferred acceptance stay open.


### 2026-11-20 — #404 document reader merged; confirmed review integration started

PR793 expected-head protected squash86c6d0d3b52b80ac0c4fc2f1662eedf712672fec
verified through plugin main/mergedPR and fetched treedd3f65a07d52fc34333a35b11c5d61b72c1987f5,
identical testedlocald6854139a7a414e745ec4142ace01fc1f03dd359. Fresh exact six-file
review remote f51b34b0a24f27ca4563061afab7ad70e2bed7b0/base277afee6 found no
blocker, threads empty. CI44726151371 Python136253948839/Flutter136253949260 every
required/poststep SUCCESS; actual Linux log confirms25reader tests active, no skips
(25in0.173s). Bounded standalone reader Done; no app/model instruction loading
claimed. Full404OPEN. Coordinator merged/outcome recorded; integration and claim
released. Owner dirty checkout/processes/stable application preserved.

Immediately claimed404-confirmed-instruction-document-review in registered issue
worktree/current verified main under existing F20, solewriter. Scope typed model,
owned host/controller/plaintextpanel integration, packagedasset and relevant tests/
shared evidence. No second independent outcome ready. Started immutable typed
ProjectInstructionObservation/Document/ReadRequest: seven-key strict JSON with
duplicate/escapedduplicate rejection, fixed selection/order, byte/base64/UTF8/NUL/
SHA256 checks and exact plain text including preservedBOM. Unknown/forged/partial
payloads throw fixedprivate errors; response and byte/document/selection lists
immutable, requestselection frozen, sourceVerified=false always. No widget/IO/model
imports or newdependencies. No current UI/caller dispatch or persistence changes.

Initial model3tests plus MVCarchitecture1 PASS. Initial analysis found seven
brace-style infos; applied scoped fixes, then twofileanalysis clean and4tests PASS.
Logs
/tmp/asg404-instruction-review-start.log and -start-analyze.log. Covers immutable
Unicode/BOM/exactbytes, unsafe/requestmutation, forged/extra/partial/duplicatewire
payloads and fixedprivacy. An initial local command used the duplicated asg path
before creating files; corrected path then reran passing tests, no product defect.
Expanded boundary/refusal/limit tests, owned helper lifecycle, readconsent/plaintext
UI, packaged Mac service and honest browser/native acceptance remain pending.
No automatic modelsharing, instructionauthority, commands/install/sourcewrites or
scheduling. FullF20/liveQwen/deferred400 open; marketplacegate/F23-last retained.


### #404 confirmed instruction-document review — final local evidence

Imported workspace now contains a manual Repository documents panel. Select only
root AGENTS.md/README.md, then explicitly confirm frozen root, selected paths and
existing configured absolute Python outside the root. No defaultpython3 fallback,
installation or automatic read. Plain selectable text, byte counts and exact
SHA256 attribution are captured data, not instruction/tool authority or current
source verification. Nothing is sent to a model, saved as instructions, scheduled,
executed as project commands or written into selected files. Existing imported
plan/store schemas and captured metadata approval semantics remain unchanged.

Typed immutable seven-key response validation enforces ordered selection/document
correspondence, exact byte length/canonicalbase64/SHA256, strictUTF8/noNUL,32KiB
perfile/64KiB total/128KiB response; rejects duplicate/escapedduplicate/unknown keys,
forged provenance, malformed/partial payloads privately. BOM/Unicode/CRLF preserved.
NativeMac host adapts the reviewed owned-helper lifecycle: packaged asset, isolated
-I-S-B launch, outside interpreter/root revalidation, owned private temp directory,
no shell/inheritedenvironment, stdout128KiB/stderr4KiB/deadline, late-start capture,
Stop/kill/reap/pipeEOF and nonrecursive cleanup. Exact requested readset binding
is required. Unsupported web/unverifiedhosts refuse production reads. Cleanup
uncertainty blocks later jobs and preserves unexpected entries; no ownerPID reuse
or process signals. Descriptor helper remains best-effort, not atomic/OSsandbox.

Controller busy/confirmation/Stop/disposal guards prevent overlapping reads and
late publication. A cancelled/failed/changed-selection refresh retains prior text
visibly stale; unknown cleanup remains sticky. No storage writes. Stop while a
confirmation is open does not pretend to dismiss that dialog; dispatch remains
blocked until it settles. View owns dialog/controller lifecycle, invalidates old
workspace consent, and renders literal plain text without Markdown execution.

45focusedcombined tests PASS, including25host/10controller/7model/2widget and
MVCarchitecture1. Host covers exact isolated arguments/environment/readset, limits,
privateerrors, deadline/Stop/late asset/temp/process startup/EOF/cancel/dispose,
interpreter/temp retarget and stickycleanup. Actual defaultpackaged Mac host reads
only disposable selected AGENTS and preserves bytes. Controller covers absent/
cancelled/frozen consent, setupchange, stale retainedfindings, Stopbeforedispatch,
late result/cleanup overlap, uncertaincleanup/disposal and wrongreadset. Widgets
pass320x800 at2xtext, cancel/read/plaintext/privatefailure/stalerefresh and replaced
workspace pendingdialog. Parser covers bytes/hash/base64/encoding/NUL/refusal/
selection/schema/duplicate bounds and immutable collections. Initial test-only
synchronous reset await removed; two analyzer style infos fixed/retested.
Logs /tmp/asg404-instruction-review-{combined-final,host,controller,panel,analysis-final}.log.

FullFlutter2411PASS13explicit skips; format591unchanged, analyzer clean, normal
webbuild and isolatednormalMacdebugbuild SUCCESS (customvalidationbundleID, no
install/launch/stableapp replacement). Pythoninstruction25/project29/coordinator20/
product32/inventory9PASS; canonicalinventory regenerated. Logs /tmp/asg404-
instruction-review-{full,format,web,mac-build,python,project-regression,coordinator,
product,inventory}.log. Mac/web packaged helper bytes match reviewed source SHA256
adbf58420bc5623942414892cf5087b7d205c4182ca7d715049cb3bf3db6fbdb. Actual builtMac
asset CLI on two disposable documents passes with unchangedbytes. Receipt
/tmp/asg404-instruction-review-packaging-ui-receipt.json records sourcehashes.

IAB supplied-data fixture visibly verified Cancel/no findings, frozen folder/files/
interpreter confirmation, selectingboth files and attributed plain-text captures.
It used memoryrecords/fakehost and no filesystem/process/model. Browser production
read capability remains unavailable. Owned loopback8393 preview server stopped.
NativeUI interaction remains UNVERIFIED (no nativeUI launch attempted this slice);
Mac service/packaging/build and IAB are distinct, not nativeUI/ownerfolder/inference
proof. Retained isolated build output is not deployment. No runtime/model changes,
installs/downloads/cloud provisioning/deployment. Full404/liveQwen/deferred400 open,
marketplacegate/F23-last retained. Final exact PR review, allrequiredCI and verified
protectedmerge remain mandatory; no full umbrella completion is claimed.


### #404 document review — fresh-review lifecycle correction and retest

Fresh review of PR794 remote103dc7c2ddf47080acb3147abba30a13e45f2a0f found a
supported injection edge: changing records while passing the same controller
caused dispose followed by reattachment of that disposed controller. Production
null-controller creation was unaffected, but lifecycle acceptance was incomplete.
_create now refuses a disposed injected instance and creates a fresh controller
for current records. Regression replaces records during pending consent, verifies
oldhost has zero reads, no listener exception, and fresh configuredPython in the
new Mac confirmation; unsupportedhosts remain disabled with no fake native claim.
Read-only source reviewer identified the edge; root fixed and freshly reviewed it.
This is pre-merge review rework, not an owner incident or escaped defect.

Revised fullFlutter2412PASS13explicit skips,46focusedPASS, format591unchanged,
analysis clean, normalweb and supplied-datafixture rebuild PASS, isolatedMacdebug
rebuild SUCCESS with verified customvalidationbundleID. Canonicalinventory rebuilt,
product32/inventory9 PASS. Logs /tmp/asg404-instruction-review-revised-{full,focused,
analyze,format,web,browser,mac,product,inventory}.log. IAB rerun visibly confirms
cancel/no findings, selectedroot/files/interpreter and two captured plaintext
provenances on rebuilt fixture. Owned8393 server stopped again. RebuiltMac/webasset
bytes match unchangedhelper; actual builtMacasset isolatedCLI passes with two
owned selecteddocuments unchanged. New receipt preserves earlier observations:
/tmp/asg404-instruction-review-revised-packaging-ui-receipt.json. NativeUI and live
inference remain unverified. Previous CI44729698989 PASS belongs to the superseded
revision and is not reused; revised exacthead/base freshreview and allrequiredCI
must pass before protectedmerge. No full404/deferred400 completion or newauthority.


### 2026-11-20 — #404 document review merged; captured context binding started

PR794 corrected head979d58f67f860e0fdb5a1906d3cf7072b83ed7e5 protected squash
a711935a69615e4421db25fcec82317e729aed4a verified by plugin main/mergedPR and
fetched tree5df1c4c494f71994bd0d3bf22e436f638abe1f4a, matching retestedlocaldfdf2d2.
Fresh exact final review resolved disposed-controller lifecycle finding; threads
empty. Revised CI44732893210 Flutter136276873037/Python136276873346 every required/
poststep SUCCESS. Bounded manual document review Done: explicit selected read
consent, plain captured provenance and owned helper lifecycle.46focused/full2412
PASS13skips, analysis/web/isolatedMac packaging/rebuilt IAB passed. NativeUI/live
inference and full404 remainOPEN; no modelsharing/source authority enabled.
Coordinator merged/outcome recorded, integration/claim released; owner dirty main,
processes and stableapp preserved.

Immediately claimed404-imported-document-context-binding, solewriter in registered
issue worktree/currentverifiedmain, existingF20 boundedcontext acceptance. Concrete
gap: document captures are manually reviewed but do not yet form a typed context
identity bound to imported metadata/requirements. Acceptance: one immutable bounded
canonical record binding exact root/metadata/validatedrequirements and selected
document path/length/digest/content; reject root/readset/refused/provenance mismatch
and overflow privately, never silently truncate. Deterministic same-input identity,
changed included inputs differ, caller mutation cannot alter captures. Explicit
untrusted-data/source_verified=false labels grant no tool/model/system/command/
installation/sourcewrite/scheduler authority. No file read/model transfer or stored
plan-format/schema change. Pure-model fixture/MVC/full required checks/freshreview/
verifiedmerge required before delivery. Byte bounds are not tokenizer/modelfit
proof; provider/UI integration and liveQwen remain later acceptance. Scope new
model/test and these three shareddocs, no second independent ready outcome.


Started pure ImportedDocumentContext.capture with fixed version/scope and immutable
canonicalJSON/evidence/digest strings. Binds exact metadata/validatedrequirements,
requestroot/selectedreadset and strict observed documents; configured interpreter
is excluded from contextdata. Includes literal untrusted-data/source_verified=false
labels, no effects/authority API.128KiB bound includes evidenceheader and JSON
expansion, rejects overflow rather than trimming. Existing importedplan/store/UI
call sites unchanged; this prerequisite is not automatically read, sent or saved.
Initial3model+MVCarchitecture1 PASS: stable exactinput identity and changedSDK/
requirementsrevision/text identity; hostileprose remainsquoteddata; wrongroot/
readset/refusedobservation privatefailures; JSONcontrol expansion limit and caller
selectionmutation isolation. One initial brace-style info corrected, then twofile
analysis clean and4checks rerunPASS. Logs /tmp/asg404-document-context-start.log and
-start-analyze.log. Expanded metadata/requirements/refusal/budget tests, fullrequired
checks/freshreview/verifiedmerge and future explicit provider/UI integration remain
pending. No liveinference/modelruntime/ownerdata/install/deployment/sourcewrite
activity. Soleclaim remainsactive, full404/deferred400 open, marketplace/F23-last
preserved. No independent second ready task was admitted.


### #404 imported document context — completed local boundary implementation

Pure ImportedDocumentContext.capture now provides immutable canonicalJSON,
attributed untrusted-evidence text and SHA256 data identity. Fixedversion1/scope,
source_verified=false, exact captured root/package/SDK/runners, validated authored
requirements/tasks and selected document path/byte_length/digest/plaintext are
included. Requestroot/readset must match the strict observed document snapshot;
all refusal statuses fail privately. Interpreter configuration is excluded from
contextdata. Hashes bind captured data only: no authentication/currentdisk proof,
model-sharing consent, plan approval, tool or execution authority is inferred.

The128KiB UTF8 cap covers the complete evidenceheader plus JSON expansion; oversize
refuses rather than truncating. Canonical data equality, not digest alone, defines
matches. Strings freeze the capture, without retaining mutable caller collections.
There is no file/service/widget/model-provider/persistence API or change to current
metadata-only ImportedPlanStore.context, plan records, source actions or scheduler.
This is a typed local prerequisite for future explicit planning/model integration,
not a claim that imported chat or source editing is delivered. Byte bounds do not
establish tokenizer/model adequacy or prompt-injection immunity; deterministic
operation/path/resource policies still control any future effects.

9modeltests plus MVCarchitecture1 PASS. Covers deterministic exact inputs and
changed root/package/SDK/runners/requirementsrevision/tasktitle/taskstatus/text;
sevenfixedrecordkeys and SHA256 of exactcanonicalbytes; wrongroot/readset and all
invalid/unsupported/changed/unavailable observations; invalid requirements/roots
with fixedprivate errors; hostileinstruction prose remainsquoteddata; no interpreter
leak; multibyte/BOM/Unicode-normalization distinctions; mutable selection
isolation; JSONcontrol expansion overflow; exactly131072evidencebytes succeed and
onebyte over refuses while preserving fullcapturedtext belowcap. Existing supplied
snapshots are caller data, not authenticated filesystem read receipts or approval.
Focused log /tmp/asg404-document-context-focused.log. Two test-only interpolation
style infos corrected before final analysis and checks. Fullrequiredchecks/fresh
exactPRreview/verifiedmerge remain mandatory. FullF20/liveQwen/deferred400 remain
open; marketplacegate/F23-last preserved. No owner data/runtime/process/install/
modeldownload/cloud/deployment/sourcewrite effects or independent second ready task.


### #404 context binding — inventory scope correction and final validation

Initial Pythoninventory9 included one failure: checked-in inventory no longer
matched regeneration after adding the model/test. The earlier progress message
claiming all inventory checks passed was corrected. No source defect or skipped
fixture was hidden. Checkpointed clean owned changes, released the original claim
and reclaimed revised404-imported-document-context-integration scope including
canonicalacceptance_inventory.json before editing it. Same F20 outcome/branch,
not another backlog item. Regenerated inventory now9PASS including exactgeneration
match. Product32/coordinator20 PASS. Original failure log remains preserved:
/tmp/asg404-document-context-inventory.log.

Final corrected-input analysis clean, fullFlutter2421PASS13explicit skips, normal
webbuild PASS, format593unchanged;10focused checks PASS. Logs /tmp/asg404-document-
context-{inventory-final,product-final,coordinator,analyze-final2,full-final2,
web-final2,format-final,focused}.log. Canonical inventory now captures current
validation inputs; no currentdisk/source/model/UI capability is inferred. This
six-file pure-model prerequisite does not change app call sites, manifests,
workflows, persistence format, document reads, model routing or execution policy.
No IAB/nativeUI/liveinference was needed or claimed for this boundary; prior manual
document review evidence stays separate. Final exactPRreview/allrequiredCI and
verifiedprotectedmerge remain mandatory. Full404/liveQwen/deferred400 open,
marketplacegate/F23-last retained; owner dirty checkout/processes/stableapp remain
untouched. No installations/modeldownloads/cloud/deployment/sourcewrite effects.


### 2026-11-20 — #404 captured context merged; manual-plan binding started

PR795 expected-head protected squashdc3922a1b7ac5026307ab185daac8dd145c3b77f
verified by plugin main/mergedPR and fetched treeff81edd4ca35716d2e760072a3c52c6261952aab,
identical testedlocal7b38f85. Fresh exactsix-file review remote
df79eb9c902a7e1db2314b91f38ca9572d77142a/basea711935 found no blocker; threads
empty. CI44735842522 Python136286881039/Flutter136286881352 allrequired/poststeps
SUCCESS. Bounded purecontext prerequisite Done;10focused/full2421PASS13skips,
analysis/format/web/product32/inventory9/coordinator20 passed after disclosed
inventory correction. No app/provider/source authority enabled. Full404OPEN.
Coordinator merge/outcome recorded, integration/claim released; owner dirty main/
processes/stableapp untouched.

Immediately claimed404-captured-document-plan-review, solewriter in registered
issueworktree/currentverifiedmain, existingF20 approved-plan acceptance. Outcome:
explicit manual plan preparation/save bound to captured documents, metadata and
current validatedrequirements, with clear local app-record persistence disclosure,
no automatic file read/model transfer/commands/sourcewrites. Acceptance: root/readset/
capture/requirements changes and stale/cancelled/uncertain state prevent admission
or invalidate affected review; preserve usertext/lastrecords and legacy metadata-
only planning. Keep existing v1keys/string-context JSONformat; captured context is
historical untrusteddata and localreviewconsent, never currentdisk/execution/model-
sharing authority. Controller/store persistence ordering/CAS/disposal/old-dialog
guards need regressioncoverage, actual honest IAB and appropriate builds. Scope
existing model/controller/panel/workspace/plan store/controller/view/tests and shared
docs/inventory. No second independent ready outcome. FullF20/liveQwen/deferred400
remainopen; marketplacegate/F23-last retained.


Started manual-plan admission guard: immutable context retains private canonical
metadata/requirements snapshots and compares current validated app inputs through
matchesPlanningInputs. Wrongroot/changedSDK/changedrequirementsrevision/invalidboard
returnfalse privately; equality is data identity only, never diskfreshness or
permission. Existing canonical record/evidence/digest bytes remain unchanged for
the same capture. Initial10model+MVCarchitecture1 PASS, twofileanalysis clean;
canonicalinventory regenerated and9inventorychecks PASS. Logs /tmp/asg404-document-
plan-start.log, -start-analyze.log and -start-inventory.log. Store/controller/view
admission, explicit local-save disclosure, persistence failure/CAS, legacy-plan
regressions and honest UI/build/fullrequiredCI/review/merge remain pending. No
plan records, document reads, model requests or source actions are enabled by this
start checkpoint. Solelease staysactive; full404/liveQwen/deferred400 open and
marketplacegate/F23-last preserved. No second independent ready task admitted.


### 2026-11-20 — #404 captured-document manual plan review validation

Implemented explicit Plan with captured documents admission after a successful,
nonstale selected-document review. Confirmation identifies root, selected files
and context SHA256 and discloses that saving stores captured text/provenance in
local application records. Cancel does not navigate or write. Revalidate current
saved folder/metadata/requirements after consent; changed inputs refuse. The
manual editor previews literal captured text and preserves existing user-authored
plan and legacy v1 four-field/string-context records. Approval is review consent
only. A legacy metadata-only view of a captured plan retains text with approval
inactive; exact same captured inputs can reopen the saved review.

Production ConditionalRecordStorage commits compare exact durable plan, folder
reference and requirements rows atomically, including stale session-cache cases.
Injected plain RecordStorage retains its guarded legacy fallback; it does not
claim cross-process atomicity. Controller disposal, replaced-editor hydration,
old-dialog admission, failed writes, changed requirements and stale editors have
regressions. Captures remain historical untrusted data, source_verified=false;
no disk freshness, document authenticity, model-sharing or execution permission
is inferred. No model request, source write, install or command is added.

Final local evidence:79focused PASS; fullFlutter2440PASS/13explicit opt-in skips;
clean analyzer;593-file zero-change format; normal web build and isolated Debug
macOS build PASS (com.arsinha.asg.documentplanvalidation, no install/native launch).
Product32/inventory9/coordinator20 PASS. Actual native Sembast close/reopen retains
BOM/Unicode/CRLF context bytes and review; controlled durable-row mutation refuses
approval while the session cache remains stale. This is database/service evidence,
not native UI/app-process relaunch evidence. Final IAB supplied-data in-memory
fixture verified explicit disclosure, save/approve and legacy approval inactivity;
earlier same-source interface checks covered cancel, captured preview and reopen.
Normal production web document actions stay unsupported/disabled. Packaged Mac/web
helper bytes match source SHA256
adbf58420bc5623942414892cf5087b7d205c4182ca7d715049cb3bf3db6fbdb.
Logs /tmp/asg404-document-plan-{focused-final2,full-final2,analyze-final4,
format-final2,web-final2,mac-final,product-final2,inventory-final2,coordinator-final}.log
and /tmp/asg404-document-plan-ui-packaging-receipt.json. Source hashes match final
UI/build receipt. Initial lazy-widget test scrolling and brace-style infos were
corrected before passing final checks; no hidden skipped failure. Owned preview
servers stopped; owner runtime/processes, dirty main and stable app preserved.

Fresh exact PR review, required final CI and verified protected merge remain gates.
Full F20/#404 stays OPEN; native UI, live Qwen, authenticated Git workflow and
unavailable-platform #400 acceptance are pending. Marketplace gate and F23-last
remain. No second dependency-ready disjoint task was admitted.


### 2026-11-20 — captured-document plan review merged; advisory boundary started

PR796 reviewed head49e0107074282ba4a94de565a88f8cd12c988fa8 protected squashmerge
ab4588cdced1c4904f91335a7595ff022017e06b verified by plugin main/mergedPR/issue404OPEN
and fetched exact tested treeb6cd50831103cc17be17fe02e6121165de638b77. Fresh exact
remote/localdiff review had no blockers, conversations empty; CI44742202772 Python
136308398263/Flutter136308398722 and every poststep SUCCESS. Bounded manual-plan
capture/save/review consent Done;79focused/full2440PASS13skips, analyzer/format/web/
isolatedMac build, actual native database reopen/stale-row checks and honest IAB
memory fixture passed. NativeUI/liveinference/fullF20 remainOPEN. Coordinator merge/
outcome recorded and integration/claim released. Owner dirty main/processes and
stable app preserved. Source publication did not deploy an application.

Immediately claimed404-imported-advisory-boundary under existingF20/#404, solewriter
in registered isolated worktree from verifiedmain. Concrete next gap: imported
workspace has captured document plans but no advisory question/consent/provider
boundary. Existing ChatController takes StudioProject and its plan prompt can
propose a generated fixed starter; it cannot be relabelled as imported source chat.
Investigation acceptance: inspect actual request/identity/Stop boundaries and use
synthetic attributed captures in a disposable provider fixture; bounded health/
models reads determine live eligibility. Identify explicit local-sharing/current-
input consent, response identity, budgets and no-effect integration prerequisites.
Only three canonical docs claimed, private disposable probes; no product source,
models, owner files, commands, cloud or provider selection changes. Captured text
stays user data, no tool/system/write/scheduling authority. Full404/deferred400,
marketplace gate and F23-last preserved; no independent second ready task.


Started investigation evidence on verifiedmerged product revisionab4588c:
ModelProvider.generate accepts one prompt string; LocalModelProvider sends exactly
one user-role message, configured model/output budget and no tools. Imported
DocumentContext.untrustedEvidence has no current provider call site. Existing
ChatController requires StudioProject, shares generated-project conversation/
requirements/plan stores and can propose fixed-starter operation contracts in Plan
mode. Reusing it unchanged would misrepresent imported-source support. A future
imported advisory controller should remain separate, with explicit selected local
endpoint/model/context confirmation, bounded question/context/history, current
capture/requirements revalidation, private errors and retained last saved answers.
Keep response prose advisory, do not parse it into edits/tools/tasks/approval.
Separate repository-context sharing consent from manual plan review consent.

Actual disposable loopback probe used current product LocalModelProvider and typed
synthetic ImportedDocumentContext, fixture IDasg-imported-advisory-fixture, not a
model/checkpoint. Seven boundary checks PASS, five synthetic HTTP responses:
exact attributed capturedJSON/hostiletext stays one userpayload with no tools;
matching response identity/output budget; contradictory identity, redirect and
truncation refuse completed response privately; omitted model remains legacy-
compatible with null completed identity; cancelled provider cannot redispatch;
external endpoint validation refuses before transport. Probe and receipt:
/tmp/asg404_imported_advisory_probe.dart and
/tmp/asg404-advisory-provider-probe-receipt.json. Server closed in finally. This
observes request construction and failure handling, not semantic injection immunity,
model fit, actual model inference, native UI or durable imported-chat history.

At2026-11-20T13:21:25.878012Z bounded GET127.0.0.1:8765/health and /v1/models both
failedURLError (0.007s/0.000s). No generation request, runtime start/stop/reconfigure,
model download or owner source access. Evidence
/tmp/asg404-advisory-runtime-observation.json. Live acceptance specifically needs
reachable healthy MLX/Metal runtime, /v1/models exactQwen3.8-27B-4bit and successful
response model ID before any live claim. Existing generic transport permits omitted
IDs for compatibility, so a strict imported coding path must not count that as
verified identity. Byte128KiB context bound does not establish token fit; explicit
refusal/budget handling and serial ownership remain necessary. Implementation can
continue independently with injected providers while live acceptance stays pending.
Next bounded implementation candidate is explicit imported read-only advisory
question/answer consent, one captured context and no tool effects, including stale
input/Stop/private-error/save-failure/disposal regressions. This investigation's
canonical checkpoint is local; required publication/CI/freshreview/verifiedmerge
are still pending, and its claim remains active for continuation. Full404/#400 and
marketplace/F23-last limits remain unchanged. No second independent ready writer.


### #404 imported advisory boundary — investigation conclusion

Resumed the owned investigation with unchanged product treeb6cd50831103cc17be17fe02e6121165de638b77.
Repeated the disposable real loopback provider probe:7boundary checks PASS/five
synthetic responses; fixture server closed. Existing local-model/streaming/response-
identity regression tests31PASS (/tmp/asg404-advisory-existing-transport.log).
No current model inference result is claimed. The earlier dated health/models
URLError observation remains historical, not silently refreshed or retried.

Bounded finding: reuse LocalModelProvider transport and explicit budgets, but add
a dedicated imported advisory controller/view and typed question/context admission.
Do not reuse generated-project ChatController plan instructions or reinterpret
Ask history keys as imported context history. First implementation should explicitly
confirm the exact local destination/model, folder/capture digest and question;
revalidate saved folder/requirements/config after consent, prohibit tool effects,
retain literal answer separately from plan approval and refuse unverified response
identity for this new path. Generic legacy transport's optional identity remains
compatible. At most one owned request, bounded Stop/timeout and private failure
handling are required. Omitted/mismatched identity, oversize context, stale consent,
failed storage and disposal cannot become completed evidence. This design does not
claim prompt-injection immunity; execution remains absent. The128KiB capture cap is
not a token-fit guarantee. Live acceptance needs reachable existing MLX/Metal runtime
and exact Qwen3.8-27B-4bit health/inventory/response identity, pending as documented.

Investigation scope completed locally; final exact PR review, required CI and
verifiedmerge still gate delivery. Only these three documentation files changed;
no product/runtime/tool/persistence/dependency/workflow change. Documentation-only
local policy does not require unrelated builds; final required CI remains mandatory.
FullF20/#404 and deferred#400 remain open; marketplace/F23-last unchanged. Original
owner dirty edits/processes and stable installation preserved. No second independent
eligible task, inference request, install, model download, cloud or deployment.


### 2026-11-20 — imported advisory investigation merged; question flow started

PR797 exact reviewed head1b413613ad7653509486bfd3d829d1f7aa68b473 protected squash
31177be5d5b33cac40a4c2c3e7d79070fa11ca7c verified by plugin main/mergedPR/issue404OPEN
and fetched treeb0f64dde286cb198fcd4fa532d5baf8011af6a80 matching local49d0245. Fresh
complete remote/localdiff review found no blockers; conversations empty. Required
CI44744171100 Python136315054525/Flutter136315054722 and every poststep SUCCESS,
including browser, normalweb and independent generatedproject checks. Bounded
investigation Done, not imported chat delivery. Seven synthetic loopback boundary
checks and31existing transport checks PASS. Dated unavailable runtime observations
remain separate; no live inference. Coordinator merge/outcome recorded; integration
and claim released. Owner dirty main/processes/stableapp preserved.

Immediately claimed404-imported-advisory-question from verifiedmain, solewriter in
registered isolated worktree under F20/#404. Outcome: one explicitly confirmed
read-only advisory question against reviewed captures, actual streaming/Stop and
retained completed local answer; no source effects. Scope covers typed request/
record, separate controller/store/view, document-panel/workspace integration,
strict database validation and relevant tests/shared docs/inventory. Acceptance:
confirm exact root/context/local destination/model/question and local-storage
consequence; stale capture/requirements/settings or cancelled/replaced consent
cannot dispatch or complete; missing/mismatched response ID never becomes verified
answer. Preserve last records/current text on transport/storage failure and Stop;
new isolated key, no legacy schema/key reinterpretation. Production conditional
save/reopen, controller disposal/save ordering, narrow UI/IAB/appropriate builds and
full required regression/review/verifiedmerge remain gates. No second independent
ready task; marketplace gate/F23-last and deferred#400 unchanged.

Started pure ImportedAdvisoryRequest.prepare: immutable exact question/captured
context/normalized local endpoint/model/output budget/prompt identity, explicit
source_verified=false. Fixed read-only advisory preamble wraps complete attributed
question/context as JSON user data, with no starter contract/tools/effects API.
8000-character question limit,24KiB complete UTF8 prompt and64KiB canonical identity
record caps reject rather than silently trim captured content. Question outer
whitespace is normalized; included data/config changes invalidate consent identity.
Existing local config validation rejects external endpoints and invalid budgets.
Neither digest nor byte admission proves model weights, token fit or injection
immunity. This model is not yet wired to a provider, storage or UI and starts no
request or permission grant.

Initial5request-model tests plus MVCarchitecture1 PASS: exact hostile/BOM/CRLF data
attribution; destination/model/budget/context/question identity and canonical
endpoint; private invalid input errors; exact24576promptbyte boundary and onebyte
refusal; JSON expansion and multibyte overflow, Unicode distinctions. Two-file
analysis clean. Canonical inventory regenerated and9checks PASS. Logs
/tmp/asg404-advisory-question-start.log, -start-analyze.log, -start-inventory.log.
Remaining controller/store/UI/consent/Stop/durability and full regression/build/
requiredCI/review/merge are pending within this same coherent task. FullF20/#404,
actual Qwen live acceptance and unavailable-platform#400 remainOPEN. No model
request, runtime change, owner source action, install, download, cloud or deployment.


### #404 imported advisory question — completed local implementation and evidence

Fresh captured-document review can now open a separate advisory question screen.
It never rereads files. Each question requires explicit confirmation of folder,
captured-context/request SHA256, normalized local endpoint, exact requested model,
question and output budget. Disclosure distinguishes sending captured metadata/
requirements/document text to that local endpoint from storing only the latest
question/answer/identity/provenance in ASG records; a successful answer replaces
this folder's previous advisory answer. Cancel retains text and sends nothing.
No generated-project prompt, operation-contract parser, source write, command,
build, plan approval or scheduling action is present. Answer text remains literal
advisory content. Hashes/data labels are not authenticity or current-disk evidence.

Separate MVC request/record/controller/store/view use the configured local provider.
Request caps are8000questioncharacters/24KiB completeUTF8prompt/64KiB identityJSON,
with no captured-content truncation. Replies cap12000characters; strict11-field
version1 record rejects duplicate/extra keys, invalid types/IDs/endpoints/budgets,
root/storage-key mismatch and corrupt data privately. New key
studio.importedAdvisory.v1.<imported-workspace-id> leaves legacy keys/formats intact.
Records retain question/answer/root/context+request digests/destination/requested+
reported model/outputtokens/time, not captured document text or raw provider errors.
The response ID must match the requested ID; missing identity is refused for this
new path while generic transport compatibility remains unchanged. This remains a
server assertion, not proof of loaded weights or model semantic correctness.

Consent and completion compare exact folder-reference, requirements, model-settings
and previous-answer inputs. Production ConditionalRecordStorage checks durable
rows in a read-only transaction before dispatch and conditionally commits completion;
changed cache/durable inputs and stale editors preserve previous answer. Injected
plain RecordStorage has guarded legacy fallback, not cross-process atomicity.
Completed responses survive failed writes for Retry saving without reinference,
or explicit discard. No partial/error/Stop/timeout/identity failure becomes a
completed record. One imported-advisory app connection per isolate is held through
bounded cancellation cleanup; uncertainty blocks redispatch and exposes Retry Stop,
including recovery of a disposed owner's uncertain connection. This is not the
future cross-feature/shared-inference scheduler, nor proof server inference stopped.
Disposal/replaced-controller consent/save-notification guards prevent late request
or state publication. Closing during an already-authorized local commit can still
leave its valid stored result; app Stop is unavailable while saving.

Final37focused PASS (request5, controller/store/nativeDB19, screen5, panel7,
MVCarchitecture1). FullFlutter2470PASS/13explicit opt-in skips;601-file zero-change
format, clean analysis, normalweb and isolatedDebugmacOS build PASS. Isolated bundle
com.arsinha.asg.advisoryvalidation was not installed/launched. Product32/inventory9/
coordinator20 PASS. Actual native database close/reopen preserves exact answer,
stale durable settings refuse dispatch/commit despite unchanged session cache,
and corrupt advisory rows are retained/quarantined without blocking unrelated
records. Widgets verify separate sharing consent, cancellation/text retention,
settings changes, replaced dialogs, storage retry and320px enlarged-text scrolling.
Initial confirmation spinner/test settlement issues were corrected; explicit
widget real-async settlement handles connection cleanup futures. Analyzer style
infos were fixed. An automatic style tool unexpectedly added hooks:any to the
manifest; only that generated line was removed immediately and original manifest
bytes verified; no dependency installation/lockfile change was performed.

IAB supplied-data fixture used synthetic providerasg-imported-advisory-fixture,
in-memory records and synthetic document helper, no model/filesystem/process call.
Observed initial disabled action, selected captures, exact sharing/storage disclosure,
Cancel retention, saved answer/reopen, missing-ID refusal preserving prior answer,
active partial/Stop/discard and failed-save/Retry saving success. Browser memory
fixture is separate from actual native DB tests; native UI remainsUNVERIFIED.
Owned8395preview server stopped. Eight product-source hashes match UI/build receipt
/tmp/asg404-advisory-ui-build-receipt.json, with Mac/web helper packaging match.
Logs /tmp/asg404-advisory-{focused-final3,full-final2,analyze-final3,format-final2,
web-final,mac-final,product-final,inventory-final2,coordinator-final}.log.

At2026-11-20T13:55:49.032113Z bounded8765/health and /v1/models bothURLError
(0.006s/0.000s), /tmp/asg404-advisory-live-eligibility.json. Zero owner-model requests;
no runtime start/stop/reconfigure/download. ExactQwen3.8-27B-4bit MLX/Metal health,
model inventory and response-ID live acceptance staysPENDING. Byte limits do not
establish token fit or injection immunity. Required finalCI/fresh exact PRreview/
verifiedmerge still gate this bounded implementation; fullF20/#404 and deferred400
remainOPEN. Owner dirtymain/processes/stableapp preserved; marketplace/F23-last
retained. No second independent ready task, unapproved install/cloud/deployment.


### 2026-11-20 — imported advisory question merged; selected-source boundary started

PR798 reviewed headf6902b90834e471e892668882473fb7011dfaa6f protected squashmerge
c437ddfb0bc83d4eb9e3c18c232f0d145cdde4d8 verified by plugin main/mergedPR/issue404OPEN
and fetched exacte2fb0f860964a8e72c2054c8537d56d2a38db9cf tree, matching local164953b.
Fresh exact full diff review had no blockers, conversations empty. CI44750045165
Python136335257359/Flutter136335257866 and all required/poststeps SUCCESS,
including browser/transport, normal web and independent generated-project checks.
Bounded explicitly consented captured-document advisory question/latest-answer
implementation Done:37focused/full2470PASS13skips, clean analysis/601-file format,
web/isolatedMac build, actual nativeDB reopen/CAS/quarantine and IAB synthetic
consent/cancel/reopen/identity-refusal/Stop/save-retry evidence. This does not verify
native UI, exactQwen live inference or fullF20; those remainOPEN. Coordinator merge/
outcome recorded, integration/claim released; dirty owner main/processes/stableapp
preserved. No source/deployment/installation/model-runtime effect was enabled.

Immediately claimed404-imported-source-context-boundary, solewriter in registered
issue worktree/currentverifiedmain, existingF20 inspect-bounded-source acceptance.
Concrete gap: new advisory flow can use root instruction documents but cannot yet
include explicitly selected source files. Existing public helper/model selection
only admits AGENTS.md/README.md. Investigation scope only three canonical docs and
private disposable probes, no helper protocol/app/model/permission changes. Examine
path/readset/payload/consent requirements before extending source capture. Full404,
deferred400, marketplacegate and F23-last stay unchanged; no independent second
ready task admitted.

Started actual Mac prerequisite probes on the verified merged revision. NinePASS
using current project_instruction_documents.Reader/inspect_documents and an owned
/private/tmp synthetic Flutter tree: public lib/main.dart selection refuses before
observation; explicit validated directory-by-directory walk yields exact nested
bytes/hash; directory and final-file symlinks, multiple hard links, source-byte
overflow and replaced readset files refuse; invalid UTF8 requires strict caller
decoding and refuses there. The internal regular primitive demonstrably accepts
raw ../outside.dart when handed directly (the outside file was also owned synthetic
fixture data). This is an extension hazard, not an exposed current public path:
the fixed whitelist rejects untrusted source paths before Reader use. Do not widen
selection by forwarding raw relative strings to regular. Future callers must
validate each component, reject absolute/empty/dot/parent/control paths and walk
all intermediate directories with descriptor-relative nofollow checks, then pass
only a single validated basename. Preserve final readset validation, length/hash/
strict-text checks, bounded selection/aggregate/output and explicit root/readset
confirmation; no recursive crawl or source execution follows from a capture.

Existing contained-document helper regressions25PASS. Probe/receipts:
/tmp/asg404_source_context_probe.py,
/tmp/asg404-source-context-probe-receipt.json and
/tmp/asg404-source-context-existing-reader.log. Fixture removed, descriptors closed;
zero owner-source reads/model requests and no public helper/app integration changes.
Reader primitives return observations, not authenticated source or atomic repository
snapshots. Source-context typing/canonical identity must be designed separately
from the fixed document protocol; do not silently reinterpret legacy captures or
plan contexts. A future sharing prompt must preview selected source identity and
remain separate from document-read consent and any write/command permission.
This claimed investigation has started with concrete evidence; publication/required
CI/freshreview/verifiedmerge remain pending for its canonical findings. Live model/
native UI and full existing-repository acceptance remain pending as recorded.


### #404 selected-source boundary — investigation conclusion and implementation contract

Resumed owned investigation; main still verifiedc437ddfb0bc83d4eb9e3c18c232f0d145cdde4d8,
no open PR or independent dependency-ready writer. Current helper/model/context/
native-host code confirms fixed root-document selection and isolated Python
-I -S -B dispatch of a privately packaged, bounded reader. Root-document payloads
and ImportedDocumentContext must retain their existing scope/format; do not label
new source files as AGENTS/README captures or silently reinterpret old plan data.
The raw regular-file primitive's caller-side basename assumption remains protected
by the current fixed public whitelist. Internal traversal probing was confined to
owned synthetic files and is not a current public exploit or source access grant.

Next bounded implementation contract under existingF20/#404: a standalone stdlib
selected-source helper with a separate version1 project-source-files observation
scope, selected_paths plus files, fixed reason/status schema and source_verified=false.
Do not change the current document helper/protocol, app call sites, source writes,
model transfers or permissions in this prerequisite. A complete helper/negative-
fixture/requiredCI increment is a coherent prerequisite; native host/typed model/
controller/view/context integration follows its own verified outcome. New reader
code must run without project/site imports under isolated Python flags; do not
weaken -I/-S or import a module from an imported repository merely to reuse Reader.
Keep the helper self-contained or load only explicitly owned packaged resources;
review duplication/refactoring against unchanged existing reader regressions.

Initial supported selection subset: one to four explicitly named unique files,
under lib/ or test/, with exact lowercase .dart extension. Preserve the confirmed
ordered selection, do not glob/crawl/discover files implicitly. Limit512UTF8bytes
per relative path,16components including root-kind and basename,128ASCIIcharacters
per component; components match [A-Za-z0-9_][A-Za-z0-9_.-]{0,127}. Reject absolute,
backslash, empty/dot/parent, hidden components, whitespace/control, non-ASCII,
wildcard and outside-subset paths, duplicate and case-fold duplicate selections.
Fail before filesystem work; never normalize an invalid path into a different
approved identity. This deliberately narrow source-path subset is not a promise
for every legitimate project/file name or other language/platform.

Walk each intermediate directory by a single validated component using descriptor-
relative nofollow directory opens. Pass only the validated final basename to the
regular reader; refuse symlink/nonregular/multiple-link files and directory
indirection. Track file identity as well as selected spelling to refuse alias/
duplicate observations. Retain stable before/open/after file signatures, directory
identity and final selected-readset checks, descriptor cleanup on every exit and
private fixed refusals with no partial payload. Keep32KiB per file,64KiB aggregate,
128KiB complete helper response ceilings; exact UTF8 bytes/base64/SHA256/plaintext
round trip (including BOM/CRLF/Unicode distinctions), strict decode and no NUL.
Refuse overflow/changed/missing/unsafe/unavailable files rather than truncating or
returning partial source. No project import, hooks/submodule/dependency/toolchain
execution, shell, package install or source write. File/directory observations are
not authenticated source or an atomic repository snapshot. A future app host still
needs explicit root/Python/readset consent, deadline, Stop and cleanup ownership;
a future model prompt retains its separate complete-input cap and sharing choice.

Repeated nine descriptor/source-boundary probes PASS and existing document helper
regressions25PASS (/tmp/asg404-source-context-existing-reader-final.log). Added a
private pure selection prototype with29PASS examples (4accepted/25refused): nested
lib/test names, exact depth, traversal/absolute/hidden/duplicate/case aliases,
backslash/wildcard/control/non-ASCII/space, component/path/depth overflow and invalid
input types. /tmp/asg404_source_selection_probe.py and
/tmp/asg404-source-selection-probe-receipt.json. The prototype is investigation
only, not a shipped parser or acceptance for future helper revisions. Nine prior
actual descriptor probes/receipts remain separately identified. No model/runtime,
owner source, native UI, app asset or public protocol effect occurred; fixtures
removed/descriptors closed. Documentation-only local policy does not require
unrelated builds; required finalCI/fresh exactreview/verifiedmerge still gate this
investigation's delivery. Full404/nativeUI/liveQwen and deferred400 remainOPEN;
marketplace/F23-last retained; owner dirty main/processes/stableapp preserved.


### 2026-11-20 — selected-source contract merged; contained source helper started

PR799 reviewed head3c05e1549097def66803d1be1dc0ea9e7282d625 protected squashmerge
8c04a06fcf93549143da30209b8726e7a2121a37 verified by plugin main/mergedPR/issue404OPEN
and fetched exact treec0ec9238cc8484f7a54498054524f0a0955dbbce matching local482b0f1.
Fresh full remote/localdiff/issue/code/probe review had no blockers; conversations
empty. RequiredCI44752768590 Python136344603443/Flutter136344603044 and every
required/poststep SUCCESS, including browser/transport, normalweb and independent
generated-project checks. Bounded source-boundary investigation Done:9descriptor
probes/29selection examples/25existing reader regressions PASS. No source protocol
or app effect was enabled by that documentation delivery. Coordinator merge/outcome
recorded; integration/claim released. Full404/nativeUI/liveQwen/deferred400 remain
OPEN; owner dirtymain/processes/stableapp and marketplace/F23-last preserved.

Immediately claimed404-contained-source-reader from verifiedmain, solewriter in
registered issueworktree under existingF20/#404. Coherent prerequisite outcome:
standalone self-contained stdlib selected-Dart source observation protocol with
complete path/readset validation and private all-or-nothing refusal, plus focused
negative/CLI fixtures and required PythonCI. Scope new helper/test, one required CI
step, shared docs/inventory; current document helper/app/provider/asset integrations
remain unchanged. New typed app host/controller/UI/source-context integration and
sharing require later verified work; no arbitrary repository execution is granted.

Started project_source_files.py with a separate version1 project-source-files/
selected_paths/files/source_verified=false record. Selection admits1–4 unique and
casefold-unique literal ASCII .dart paths under lib/test, <=512pathbytes/16components/
128chars per component; invalid types/control/surrogate/hidden/traversal/wildcard/
absolute/backslash/ambiguous names refuse before filesystem calls. Selection is
frozen, and each validated directory component/final basename is passed separately
to nofollow descriptor primitives. Reader is self-contained for isolated-I-S-B
execution, mirroring existing root-document descriptor semantics with source-specific
refusal mapping. Single-link regular files only, repeated file identity guard,
stable signatures/final readset validation, strict UTF8/noNUL,32KiB perfile/64KiB
aggregate/128KiB output, exact byte length/base64/SHA256 and no partial captures.
No project modules/hooks/commands/network/model/source writes are invoked.

Initial7actual Mac tests PASS: exact ordered nested lib/test capture including BOM/
CRLF/Unicode bytes and fixed schema;26invalid selection subcases open nothing;
only single validated components reach directory/file operations; selected file/
directory symlinks, hard links and missing files refuse; exact size/aggregate bounds,
strict encoding/NUL and overflow return no partial payload; replaced file fails
final validation; isolated real CLI runs from a synthetic project with hostile
sitecustomize without importing it and refuses traversal privately. Existing
instruction25/metadata29 regressions, product32/inventory9/coordinator20 PASS.
Canonical inventory regenerated unchanged. Added only a required selected-source
Python step; existing check names/commands/action pins/permissions/timeouts and
protections retained. Logs /tmp/asg404-contained-source-{start,doc-regression,
metadata-regression,inventory-start,product-start,coordinator-start}.log.

This is a local start checkpoint, not delivered app source-reading support. Expand
root/directory/read races, descriptor cleanup, duplicate identity, unsupported-host/
private-error and CLI/output-boundary negatives; then run required regressions,
fresh exact PRreview/allrequiredCI/verifiedmerge before delivery. Current public
instruction protocol and app assets unchanged; no nativeUI/live model/platform
support assertion, owner-source read, install/download/cloud/deployment or second
independent ready task. Claim remainsactive for continuation.


### #404 contained selected-source helper — final local implementation and validation

Standalone project_source_files.py now supplies the separate version1
project-source-files observation protocol: fixed seven envelope keys, ordered
selected_paths/files and source_verified=false. Each successful item has only
path/byte_length/SHA256/base64; strict UTF8/noNUL is validated without transforming
BOM/CRLF/Unicode bytes. One to four exact unique/casefold-unique ASCII .dart files
under lib/test;512pathbytes/16components/128chars percomponent. Invalid/traversal/
absolute/hidden/wildcard/backslash/control/surrogate/type/depth/size selections
refuse before opens. No input normalization or implicit recursive discovery.

Each directory is opened by one admitted component, final source by basename,
with read-only nofollow flags and nonblocking file open. Regular/single-link files
only; repeated file identities, stat/open/read/final signatures and directory/
root/ancestor replacements refuse.32KiB/file64KiBaggregate128KiB output ceilings,
all-or-nothing private fixed refusals and reverse-order descriptor close on every
exit. Namespaced source refusal codes are emitted directly; the initial legacy
reason translation shim was removed for a self-contained source protocol. The
helper deliberately mirrors descriptor semantics while remaining standalone for
Python-I-S-B with no project/site imports. Existing document helper/model/context,
app assets, native host, controllers and views remain unchanged. No source writes,
project imports/hooks/commands, scan, process/network/model dispatch or permission
expansion. Observations are historical data, not authentication or atomic source
snapshots. A future app caller must own explicit root/Python/readset consent,
deadline, Stop, output caps and cleanup; separate sharing consent still applies.

Final31actual Mac/POSIX tests PASS, covering fixed schema/exact ordered nested
bytes, invalid selections with zeroopens, maximum component/path/depth and actual
512byte/16component reads, frozen readset, selected-only reads, zero-length/four
sources/exact64KiB total, source/aggregate/output overflow, strict text, Unicode
normalization distinctions, links/FIFO/directories, stat-to-open FIFO/symlink/
disappear/growth/hardlink races, midread truncation/growth/same-size changes,
same-byte replace/unlink, directory/root/ancestor replacement, simulated duplicate
file identity, private open/read/validation errors, unsupported API/host, all-owned
FD close+EBADF verification, malformed/isolatedCLI from hostile project cwd and
fixed refusal output. Open-flag regression forbids create/truncate/append/follow;
no-scan/high-level-open/process/network/write hooks are exercised. CLI subprocesses
complete under bounded test timeouts and do not execute fixture source.

Adjacent document25/metadata29 regressions PASS; product32/inventory9/coordinator20
PASS. FullFlutter2470PASS13explicit opt-in skips,601-file zero-changeformat, clean
analysis and normalwebbuild PASS. Logs /tmp/asg404-source-reader-{focused-final2,
doc-final,metadata-final,inventory-final,product-final,coordinator-final,format-final,
analyze-final,full-final,web-final}.log and final source/test hash receipt
/tmp/asg404-source-reader-final-receipt.json. No app/runtime input changed, no new
app asset/nativeUI/IAB behavior was enabled; actual Mac CLI evidence is separate
from later app-host/device support. Added exactly one required PythonCI step for
this suite, retaining every old step/check name, action pin, read-only permission,
timeout and protection. No dependency/install/model download/cloud/deployment.

Final exactPRreview/allrequiredCI/verifiedmerge remain delivery gates. This is a
complete bounded standalone observation prerequisite, not app source-read, native
UI, model-sharing or wholeF20 acceptance. Full404/liveQwen/nativeUI and deferred400
remainOPEN; marketplace/F23-last retained. Owner dirtymain/processes/stableapp
preserved and no second independent ready task admitted. Next eligible outcome
after verifiedmerge is explicit in-app selected-source capture/review with the
same typed readset, identity, consent and owned helper lifecycle; model-sharing
integration remains a separate validated boundary.


### 2026-11-20 — contained source helper merged; app source review started

PR800 reviewed head5ce5cd2b53fe836ece45a0261ecfc52ca7aeeef0 protected squashmerge
6c0de187b3fa7fc7b01d9db937f3133c6b45311b verified by plugin main/mergedPR/issue404OPEN
and fetched exact tree6c6da47de89ed242d592affb22f86ad19fac08dd matching local6f68e8b.
Fresh full remote/localdiff/source/fixture/workflow review had no blockers; threads
empty. RequiredCI44755977765 Python136355684638/Flutter136355684071 and every
required/poststep SUCCESS, including browser/transport, normalweb and independent
generated-project checks. New required source suite ran31active Linux/Python3.12
tests PASS, distinct from31actualMac/POSIX tests. Local full2470PASS13skips,
analysis/601-fileformat/web/document25/metadata29/product32/inventory9/coordinator20
PASS. Bounded standalone helper Done; not app source selection, model sharing,
nativeUI or fullF20. Coordinator merge/outcome recorded, integration/claim released;
owner dirtymain/processes/stableapp preserved, full404/liveQwen/deferred400 open.

Immediately claimed404-selected-source-review from verifiedmain, solewriter in
registered issueworktree. Coherent outcome: explicit source-path form and exact
root/existingPython/readset confirmation, trusted packaged helper execution with
deadline/Stop/cleanup ownership, literal source capture/provenance/stale/error UI;
no source writes, text persistence, model sharing or plan/command authority. Scope
new pure typed model, host interface/factory/native/stub, controller/panel and
workspace entry/asset, relevant model/controller/host/widget tests and shared docs/
inventory. Preserve current instruction/plan/advisory formats. Unsupported platforms
remain explicit; actual Mac helper/injected lifecycle regressions, IAB supplied-data
UI, web/isolatedMac build/fullrequiredchecks/freshreview/verifiedmerge remain gates.
No second independent ready task; marketplace/F23-last and deferred400 unchanged.

Started pure ProjectSourceObservation/ProjectSourceFile/ProjectSourceReadRequest.
Strict separate project-source-files envelope/status/reason/readset/file-key parser,
128KiB whole response,32KiB/file64KiB aggregate, canonical base64/length/SHA256,
strict UTF8/noNUL and immutable selected-path/file/byte snapshots. Preserves BOM,
CRLF and Unicode byte distinctions; source_verified=false never authenticates a
helper capture or current disk. Literal ASCII lib/test Dart selection mirrors the
verified helper limits, rejects duplicate/case aliases, traversal/hidden/control/
non-ASCII/surrogate/ambiguous paths and overflow. Frozen request inputs are data,
not read consent; host-side root/Python validation and explicit user confirmation
are still pending. No process, storage, provider or UI call site added by this start.

Initial8domain+MVCarchitecture1 PASS: exact attributed bytes/order/immutability,
selection boundaries/refusals/frozen request, strict envelope/legacy-scope/duplicate
and invalid fields, byte/hash/base64/path/text mismatch, exact per-file/aggregate/
whole-response ceilings and typed refusals with no partial source. Two initial
brace-style infos corrected manually, then two-file analysis clean and ninechecks
rerunPASS. Canonical inventory regenerated;9inventorychecks PASS. Logs
/tmp/asg404-selected-source-model-start-final.log,
/tmp/asg404-selected-source-model-start-analyze-final.log and
/tmp/asg404-selected-source-model-start-inventory.log. Host/controller/view/assets,
actual Mac helper lifecycle/UI/build/fullCI/review/merge remain pending within the
same task. No owner-source read/model request, runtime/install/download/cloud/
deployment effect; claim remainsactive for continuation and fullF20 staysOPEN.


### 20 November 2026 — F20/#404 selected-source review implementation

Continued claimed404-selected-source-review. Added separate MVC controller,
conditional host and selected-source panel to the imported workspace. Explicit
confirmation shows exact root/existing Python/readset and4file/32KiBfile/64KiBtotal
limits. Literal ASCII lib/test .dart paths only; no scan. Changes to Python while
consent is open prevent dispatch. Replaced/disposed workspace and Stop drop late
results; previous captures remain visible stale after failure/selection changes.
No source persistence, model transfer, plan approval or command authority.

Native Mac host runs only packaged project_source_files.py using existing outside-
project Python -I -S -B/fixed argv/private owned temporary directory. Bounded
stdout/stderr/deadline and owned-handle kill/reap include late startup; uncertain
cleanup blocks overlapping reads. Strict parser/readset and exit status agree:
0observed/2typed refusal; an exit2successful capture refuses. Unsupported hosts
remain explicit. Existing document/advisory/plan formats untouched; one helper
asset added, no dependency/lockfile change.

Validation: initial45model/controller/host/architecture plus4widget checks PASS;
finalhost26 and finalwidget5 PASS, including actual Mac packaged helper against
owned disposable lib/main.dart, exact32KiB response bytes, private failures,
late process/temp startup, Stop/disposal, interpreter retarget, uncertain cleanup,
wrongreadset, confirmation/workspace replacement and320px/textscale2. FullFlutter
2518PASS/13explicit skips before two additional test-only cases; runtime code
unchanged thereafter. Full analysis clean;612Dartfiles formatted; mainweb build
PASS. SourcePython31/inventory9/product32/coordinator20 PASS. Product suite first
attempt used a nonexistent filename; corrected to test_product_acceptance.py and
32PASS. Narrowwidget initial ambiguous scroll finder corrected to explicit outer
scrollable;5PASS. No product change was needed for this fixture failure.

Isolated macOS build PASS: bundle com.arsinha.asg.sourcereviewvalidation, private
DerivedData, exact packaged sourcehelper bytes verified. Build is not native UI
launch evidence. Separate supplied-data IAB fixture verified explicit Cancel,
confirmation/capture, literal untrusted link text/hash/bytes and stale warning;
no real repository reads/model requests/storage. Owned8396preview server stopped.
Logs /tmp/asg404-source-review-{analyze,full,web,native,format,reader,inventory,
product,coordinator-test}.log, /tmp/asg404-source-host-final.log,
/tmp/asg404-source-panel-final.log and /tmp/asg404-source-browser-build.log.
Required remote CI, exact fresh PR review and verified merge pending. FullF20,
source-context sharing/chat integration and unavailable-platform400 acceptance
remain open. Marketplace gate/F23-last preserved. Claim retained through review.


### 2026-11-20 — selected-source review merged; source-context investigation started

PR801 fresh reviewed head2f3bb0e83e7c1d06180cf5f87ac41355fe246279 protected squashmerge
5b0c3b63df0e85b03ad6cd08ececd52b68a85e22 verified by plugin main/mergedPR/issue404OPEN
and fetched exact tree6caa27a0133d0ce4a339db97ae9c7c4ae516d880 matching local64734eb.
Full remote/localdiff identical after index abbreviation normalization; strict model,
request/consent/setup/lifecycle/nativehost/UI/tests reviewed with no blockers;
threads empty, head/base unchanged. RequiredCI44759979146 Python136369605984 and
Flutter136369606813 all required/poststeps SUCCESS; completed logs inspected,
including source31, fullFlutter, actual browser storage/transport, staticHTML,
mainweb and independent generatedFlutter project checks. Local full2518PASS13skip,
finalhost26/widget5 including two added test-only cases PASS, analysis/612fileformat/
web/isolatedMac exacthelper/IABsynthetic/Python suites as recorded above. Bounded
in-app selected-source read/review delivered; fullF20/nativeUI/liveQwen not claimed.
Coordinator merge/outcome recorded, integration and completedclaim released.
Dirtyowner main/stableapp/ownerprocesses preserved; preview8396 stopped.

Immediately claimed404-source-context-boundary investigation from verifiedmain in
registered directissueworktree, solewriter. Scope three shared canonical docs;
no product/model/schema changes. Outcome: identify concrete typed captured-source
identity and explicit sharing prerequisites before extending document-only advisory.
Read ProjectSourceObservation/ReadRequest, ImportedDocumentContext and current
ImportedAdvisoryRequest.prepare and existing puretests. Advisory context is final
ImportedDocumentContext with instruction-document list; there is no production
source context/advisory route. Observation alone has no selected-root/metadata/
requirements/destination identity. Do not relabel source as instruction documents.

Started4disposable pure Mac probes plus existing source observation/documentcontext/
advisoryrequest regressions:28PASS. Valid32768byte source exceeds current24KiB
wholeprompt admission;16384 literal quote bytes expand beyond24KiB in JSON even
before prompt framing. Identical captured bytes can be selected from distinct roots;
future context must bind exactroot/readset/bytes/metadata/requirements and sharing
consent, rather than treating a leafhash as full request identity. LF/CRLF/BOM
captures retain distinct hashes and originaltext. Existing document fixture was
used only to measure its transport admission, never as a production source route.
No source truncation, runtime requests, source reads/writes, durable schema changes,
installs/downloads/cloud/deployment. Temporary probe
/tmp/asg404_source_context_probe_test.dart; log/tmp/asg404-source-context-start.log.

Continue this owned investigation with source/context byte-budget and compatibility
failure cases, then record one bounded typed source-context implementation in this
canonical queue under404. Source sharing/chat remains pending; fullF20 and deferred
400 remainOPEN, marketplacegate/F23-last unchanged. No independent disjoint second
ready task was admitted. Claim remainsactive for continuation.


### 20 November 2026 — captured-source context boundary findings

Completed bounded local investigation under404-source-context-boundary. Eight
synthetic pure probes plus source/documentcontext/advisoryrequest regressions:
32PASS (/tmp/asg404-source-context-final.log). An initial additional store-test
filename did not exist; corrected invocation reran all32PASS; no test removed from
production suite. Existing imported_advisory_test separately exercises storage/CAS,
Stop and response identity. No production code or schema changed.

32768 valid source bytes can exceed24KiB whole advisory prompt. 16384 quote bytes
expand beyond24KiB JSON;32768 allowed nonNUL control bytes expand beyond128KiB
captured-context ceiling. Admission must measure serialized UTF8 including framing,
refuse whole oversized input and retain exact captured bytes; no truncation.
Existing document-only context is final and source observations have no root/
metadata/requirements identity. Legacy answer decoder rejects appended source_text;
ordinary encode/decode remains stable. Source context must not be relabelled as
instruction documents or silently inserted into old saved records. Current advisory
controller/store is explicitly typed to ImportedDocumentContext and performs saved-
input CAS before dispatch/completion; later source sharing requires separate visible
consent with captured context/destination/model and the same lifecycle guarantees.
These are deterministic fixtures, not live model/nativeUI/platform acceptance.

Next eligible bounded implementation under existingF20/#404: claimed typed captured
source context prerequisite after this investigation's verified merge. Acceptance:
new pure immutable ImportedSourceContext binds exact selectedroot, inspection and
validated requirements, ordered selectedpaths and exact source text/bytecount/hash;
validate requestroot/observationstatus/readset, serialize a versioned separate scope,
source_verified=false, retain BOM/CRLF and immutable snapshots. Whole serialized
untrusted evidence bounded128KiB; fail privately for overflow/mismatch/corrupt
requirements, never truncate. Stable digest changes with root/pathorder/bytes/
metadata/requirements. Compare current planninginputs without claiming currentdisk
verification, read permission, storage or sharing. Do not alter instruction context,
advisory record/store/prompt formats, controller/UI or existing helper. Focused
boundary/immutability/error/identity tests, architecture/analyze/fullregression/web,
requiredCI/freshreview/verifiedmerge gates. Source advisory sharing integration is
later acceptance. This is the sole selected next task; no speculative backlog or
second independent writer. FullF20, liveQwen/deferred400 and F23-last/marketplacegate
remain unchanged. No model/process/runtime/install/sourcewrite/deployment effects.


### 2026-11-20 — source-context investigation merged; typed context started

PR802 fresh reviewed head5c67474e1160c022ba680e578e34b766b4c05ea0 protected squashmerge
c908fac41b8abacb320c78fd929628985c4ab0d2 verified by plugin main/mergedPR/issue404OPEN
and fetched exact testedtree d74608e50d7d6fd3c5b2ee22c11e89847a0d377b matchinglocal
4ca9ee7. Full remote/localdiff review no blockers, emptythreads, unchangedhead/base.
RequiredCI44762012471 Flutter136376712061/Python136376712395 every required/poststep
SUCCESS; completedlogs inspected fullFlutter/browserstorage/transport/staticHTML/
web/independentgeneratedFlutter/Python suites. Investigation32pure/probe plus19
advisory storage/CAS/Stop/identity checks PASS. Coordinator merge/outcome recorded,
integration/claim released; no product behavior or permission expansion claimed.

Immediately claimed404-captured-source-context from verifiedmain in same registered
issueworktree, solewriter. Scope pure ImportedSourceContext/modeltests plus canonical
history/requirements/architecture/inventory only. Started separate versioned immutable
captured-imported-source-context with source files/root/metadata/requirements/order/
text/hash identity, requestroot/readset/observed checks,128KiB whole UTF8 evidence
limit, source_verified=false and planninginputs comparison. Existing instruction/
advisory/storage/helper/UI paths unchanged, no sharing/permission/IO callsite added.

Initial11context+1architecture PASS: stable and changed identities; wrongroot/readset/
refusals/private errors; JSON-expansion bound; immutable snapshots; metadata/authored
requirements/tasks/currentplanninginput comparisons; all refusals; ordered files.
Two-file analysis clean; inventory regenerated and9inventory checks PASS. Initial
mechanical copy briefly produced an invalid local identifier before formatting;
corrected before tests, no published revision or product effect. Logs
/tmp/asg404-captured-source-start.log,
/tmp/asg404-captured-source-start-analyze.log and
/tmp/asg404-captured-source-start-inventory.log. Continue exact boundary/fourfile/
BOM/CRLF/order/compatibility scenarios and full regression/web/requiredCI/freshreview/
verifiedmerge before completion. No model requests, owner-source reads, process/
install/download/stableapp/cloud/deployment effects. FullF20/source-sharing and
unavailableplatform400 remain OPEN; marketplacegate/F23-last preserved. Activeclaim
retained for continuation; no second independent dependency-ready track admitted.


### 20 November 2026 — captured-source context validation

Completed pure ImportedSourceContext implementation under404-captured-source-context.
Separate captured-imported-source-context identity binds selected root/inspection,
validated requirements and ordered exact file text/bytecount/hash; immutable source
objects preserve bytes. Whole untrusted-evidence UTF8 cap128KiB, private mismatch/
overflow/refusal errors and source_verified=false. App input comparison is captured
identity only, never disk verification/sharing/read/plan/command authority. No UI,
provider/storage/helper or existing instruction/advisory format changes.

Final30focused source/document/advisoryrequest/architecture checks PASS, including
exact128KiB evidence/onebyte overflow, expansion/multibyte/BOM/normalization,
root/allmetadata/requirements/tasks/refusal/readset identity, snapshots and four
ordered files at exact65536aggregatebytes with BOM/CRLF/emptyfile. Order reversal
changesdigest. One new test initially expected mutation of original constructor
lists to alter metadata/requirements, but both existing classes copy those lists;
corrected to assert stable oldsnapshot and reject newlyconstructed changedinputs.
No product fix was needed. Full analysis clean;614Dartfiles formatted; inventory9/
product32 PASS. FullFlutter/web results and exact remote CI/review/merge recorded
in PR evidence; do not mark fullF20 complete. Logs
/tmp/asg404-captured-source-{focused,analyze,full,web,format,inventory,product}.log.

Next eligible coherent F20/#404 implementation after this verifiedmerge: explicit
advisory questions about captured source. Bind the final source context to a typed
advisory input, expose a captured-source review action with metadata/requirements
matching and no automatic reread, then reuse existing bounded question/answer,
explicit per-request destination/model/context consent and storage CAS/Stop/retry/
responseidentity guarantees. Preserve existing document request/record formats and
behavior; source context stays distinct in its versioned captured payload. Measure
whole serialized prompt and refuse oversized source without truncation; retained
capture/previous answer survive refusal. New source text remains untrusted data,
not command/plan authority. Default unavailable hosts remain explicit. Regression
coverage must include source content/root/order/requirements/settings changes,
consent cancellation/disposal, failed save/retry, matching response ID, source prompt
budget, legacy document compatibility, native storage reopen and supplied-data IAB;
full format/analyze/tests/web/isolatedMac/requiredCI/freshreview/verifiedmerge gates.
Only later explicitly consented local inference may use the configured owner Qwen
runtime after health/models/responseID verification; unavailable runtime leaves that
acceptance pending. No deployment/install/owner sourcewrite or new arbitrary code
execution. This is the sole next task, not a second backlog; no independent ready
writer admitted. FullF20/deferred400/F23-last and marketplacegate unchanged.

Final local fullFlutter2533PASS/13explicit opt-in skips and mainwebbuild PASS.
Runtime source unchanged after these checks; no native UI or live model claim.


### 2026-11-20 — captured source context merged; source advisory started

PR803 fresh reviewed head20b348f58714e572bbc55d2950c358d4b549fd93 protected squashmerge
f7282ef0f2af696e01c5d08f136f3e5185b3b661 verified by plugin main/mergedPR/issue404OPEN
and fetched exacttree74ed02e88d47fe3ad1a708490f342ed48d3c3c6b matching localbae3513.
Full remote/localdiff matched; private typed capture/root/readset/status/bytebudget/
immutability/identity/compatibility review no blockers, emptythreads, unchangedbase.
RequiredCI44764767750 Python136386321031/Flutter136386321730 every required/poststep
SUCCESS; completedlogs inspected new exactcap/fourfile tests, fullFlutter/browser/
transport/staticHTML/web/independentgeneratedFlutter and Python suites. Local30
focused/full2533PASS13explicit skips/analyze/614fileformat/web/inventory9/product32
PASS. Pure sourcecontext Done, not source sharing or fullF20. Coordinator merge/
outcome recorded, integration/claim released; unrelatedownerstate preserved.

Immediately claimed404-captured-source-advisory from verifiedmain, solewriter in
registeredissueworktree. Contract covers typed document/source advisory input,
explicit captured-source review action, separate destination/model/context sharing
consent, bounded prompt/refusal, existing durableCAS/Stop/cleanup/failedsave retry/
responseidentity and previousanswer guarantees, legacycompatibility and actual
relevant fixture/UI/build/requiredCI gates. No second independent ready task.

Started pure ImportedRepositoryContext interface and implemented read-only
capturedFiles/includesSource metadata in existing final document/source captures.
Payloads remain separate versioned scopes; immutable literal path/text/bytecount/hash
attribution only. Existing document requests/payloads unchanged. Before editing,
one synthetic legacy baseline fixture recorded requestSHA
3da7af058494f289036bd4fa9acbae5b88a717f591f36b6bdeb48b8f8c321bec and contextSHA
c80c69217fd617297c0f959fdb09a0e5fbd6a528777d16ab6a6c6e28713eec0b. New regression
asserts both exact identities remain unchanged and document/source scope distinction,
BOM/CRLF/literal untrustedlink attribution and immutable API lists. This interface
is app-owned typed data, never model-sharing or execution authority.

Initial32focused context/legacyrequest/architecture checks PASS, fourfileanalysis
clean after eight required override annotations added manually; inventory regenerated
and9inventorychecks PASS. Logs/tmp/asg404-source-advisory-legacy-baseline.log,
/tmp/asg404-source-advisory-context-start.log,
/tmp/asg404-source-advisory-context-analyze.log and
/tmp/asg404-source-advisory-context-inventory.log. No advisory request/controller/
store/UI callsite uses source yet. Continue consent/workflow integration, nativeDB/
IABsynthetic/error regressions and fullbuild/requiredCI/review/verifiedmerge. No model
requests/owner-source reads/writes/install/download/cloud/stableapp effects. FullF20,
source sharing/liveQwen and unavailableplatform400 pending; marketplacegate/F23-last
preserved. Activeclaim retained for continuation.


### 20 November 2026 — captured-source advisory implementation and local validation

Continued404-captured-source-advisory. Imported advisory request/controller/store
now consume typed ImportedRepositoryContext; concrete final document/source captures
retain distinct versioned payloads and exact legacy document request/context hashes.
Source prompts label captured source as untrusted data; limits remain8000question,
24KiBwholeprompt/64KiBrequestidentity/12000answer and exactmatchingresponsemodelID.
No truncation, generated operation contracts or new execution authority.

ProjectSourceController retains exact readrequest, prepares a pure sourcecontext only
for a fresh nonbusy/cleanup-confirmed capture and saved reference with matchingroot/
current validated requirements. Sourcepanel exposes Ask about captured source only
when eligible; importedworkspace opens existing advisoryscreen with that context.
No automatic reread/providercall on navigation. Source-specific literal review and
separate destination/model/context/question sharing confirmation explain latestanswer
storage and historical/unverified status. Source capture itself is not copied into
answerrecord; answer prose and provenance use existing strict format/key. Existing
advisory durable predispatch/completionCAS, previousanswer retention, Stop/disposal/
cleanupownership and failedsave-only retry are reused without permission expansion.

Final60focused PASS: legacy hashes and document compatibility, distinct sourcepayload/
BOM/CRLF, exactprompt expansion refusal, eligible savedcapture/stale/root/corrupt
requirements, sourcebutton/dialog/cancel/send, changedsettingsconsent refusal,
source missing/wrongresponseID, failedsave retrywithoutinference and Stop retaining
oldanswer. Actual native source DB close/reopen retained exactsavedanswer; changed
durable settings refuse dispatch despite unchanged cache. Existing document storage,
CAS/error/disposal regressions remainactive. FullFlutter2547PASS13explicit skips;
fullanalysis clean;616fileformat; mainweb/isolatedMacbuild PASS; inventory9/product32
PASS. One initial braceinfo corrected manually. Logprefix
/tmp/asg404-source-advisory-{focused,analyze,full,web,native,format,inventory,product}.

IsolatedMac bundlecom.arsinha.asg.sourceadvisoryvalidation, exact sourcehelper asset
and10runtime sourcehashes recorded in/tmp/asg404-source-advisory-build-receipt.json.
No install/stable replacement/nativeUIlaunch. Supplied-data IABfixture used synthetic
source/provider and memoryrecords: readconfirmation->capturedsource->question,
literal capturedreview, sharingCancel, separateconfirmedsyntheticanswer, return/
reopen previousanswer, failedsave preservingoldanswer/completedunsavedanswer and
Retry saving recovery PASS. Browserfixture build log
/tmp/asg404-source-advisory-browser-build.log; owned8397previewserver stopped.
Runtime probe2026-11-20T15:51:16.631755Z /health and/v1/models bothURLError,
zeroinference requests. No fresh Qwen/liveweight/responseidentity claim; owner
processes untouched. RequiredCI/fresh exactreview/verifiedmerge pending.

Next eligible bounded F20/#404 prerequisite after verifiedmerge: inspect manual
change-plan storage/approval boundaries for captured source. Existing manual plan
flow accepts captured instruction documents; source advisory must not silently
approve a change or treat source context as documents. Investigation scope current
model/controller/store/tests, source/context identity binding and staleapproval/
legacyformat compatibility, using deterministic owned fixtures on this Mac. Record
one concrete source-backed manual-plan implementation with acceptance in this sole
queue; no arbitrary repo edits/commands, automaticapproval, model request or schema
migration during investigation. Reuse404, preservefullF20/deferred400/F23-last and
marketplacegate; no independent disjoint readywriter admitted. No install/download/
cloud/deployment/owner-sourcewrite effects. Claim held through finalreview/merge.


### 2026-11-20 — source advisory merged; source-plan boundary investigation started

PR804 fresh reviewed head486a65b583a0af42fda4d301bb692961198aac44 protected squashmerge
3694350855f4204cd8fd00439f880b2adc900d3b verified by plugin main/mergedPR/issue404OPEN
and fetched exacttreef24216ec0bf2e6da31c369e5dd6cfa8ddce31216 matching localb3fa952.
Full20file remote/localdiff match; typedcontext/legacyidentity/sourceeligibility/
sharingconsent/CAS/Stop/retry/privatefailures/previousanswer review no blockers;
emptythreads unchangedhead/base/main. RequiredCI44768507157 Python136399534052/
Flutter136399534481 every required/poststep SUCCESS; completedlogs inspected new
source responseID/failedsave/nativeDBreopen plus legacy/fullFlutter/browserstorage/
transport/staticHTML/web/independentgeneratedFlutter/Python suites. Local60focused/
full2547PASS13explicit skips/analyze/616fileformat/web/isolatedMac/inventory9/product32
and IABsynthetic consent/cancel/save/reopen/failedsave retry PASS as recorded above.
Explicit captured-source advisory boundedfeature delivered; owner runtime /health and
/v1/models unavailable at15:51:16UTC, zero liveinference; nativebuild is not nativeUI.
FullF20/liveQwen/deferred400 remainOPEN. Coordinator merge/outcome recorded,
integration and completedclaim released; ownerdata/processes/stableapp preserved.

Immediately claimed404-source-plan-boundary from verifiedmain in registered direct
issueworktree, solewriter, threecanonicaldoc scope. Inspected actual ImportedPlan,
ImportedPlanController/Store and captured source. Production store/controller still
accept only ImportedDocumentContext; existing source-advisory answer cannot create
manual plan or approval. Plan context is an opaque serialized string; source-backed
planning needs explicit typed context admission and source-specific storage consent,
while preserving legacy record formats and current-input approval comparison.

Started two disposable pure/record/controller probes plus existing imported-plan
regressions:24PASS, including actual native DB reopen/stale durable CAS from existing
suite. ImportedPlan roundtrip can retain a synthetic source-context string and raw
approved flag, but current legacy metadata plan controller correctly reports current
false/approvedfalse and preserves the mismatched record withoutwrites. This is not a
production sourceplan route or execution credential. /tmp/asg404_source_plan_probe_test.dart
and /tmp/asg404-source-plan-start.log retain probe/evidence. No automatic approval,
source edits, commands, schema mutation, model requests, installs/downloads/cloud/
deployment effects. Continue source/current-input/legacy compatibility boundaries,
then record one bounded source-backed manual-plan implementation in REQUIREMENTS.
No independent disjoint readywriter; marketplacegate/F23-last unchanged. Activeclaim
retained for continuation.


### 20 November 2026 — source-backed manual-plan boundary findings

Completed bounded local investigation404-source-plan-boundary. Five temporary
source/record/controller probes plus existing imported-plan suite:27PASS, including
actual native DB reopen and durable stale-inputCAS. Log/tmp/asg404-source-plan-final.log;
probe/tmp/asg404_source_plan_probe_test.dart. No production plan/store/controller/UI
or schema changed. Existing record shape{text,context,approved,recordedAt} roundtrips
exact source-context JSON/BOM/CRLF; source root/byte changes alter full contextstring.
The raw approved flag is not current approval: both metadata-only and captured-
document controllers preserve a mismatched synthetic sourceplan withoutwrites and
report currentfalse/approvedfalse. Legacy capturedDocuments constructor rejects a
source object by type. No source->document relabelling or automatic approval route.

Inspected store save and production conditional commits: draft must already match
current exact text/context before approval; saved-record optimistic comparison and
full context/requirements/root reads participate in durableCAS. Existing controller
current/approved recalculate context compatibility; source mode must preserve those
guards, lastworking draft and failure behavior. UI currently names capturedDocuments
and explicitly discloses local captured-text storage, so adding a source type only
at the record layer would omit necessary consent/review semantics.

Next eligible bounded F20/#404 implementation after this investigation verifiedmerge:
explicit source-backed user-authored manual plans. Add optional typed capturedSource
admission alongside legacy capturedDocuments in ImportedPlanStore; reject ambiguous
simultaneous contexts. Preserve old constructor/record/key/metadata/document behavior;
select exact sourcecontext only when root/metadata/validatedrequirements match. Copy
selected typed context into transactional save snapshots, retain draft-before-approve,
current-input/durableCAS/record-staleness and inactiveapproval on context mismatch.
Controller and view expose source review/provenance without rereading files. Source
panel opens manualplan only from fresh eligible capture and a separate explicit
localstorage confirmation disclosing captured source text/provenance persistence;
recheck source capture/root/requirements/metadata after consent before navigation.
No advisory answer imports, model call, automaticplan/approval, sourcewrite/command/
execution authority. Empty/changed/corrupt/stale/disposed/cleanup-uncertain or cancelled
inputs retain oldcapture/plan and refuse. Relevant legacy/source controller/store/UI,
actual nativeDB reopen/staleCAS and supplied-data IAB consent/cancel/storage/reopen
regressions; fullformat/analyze/tests/web/isolatedMac/requiredCI/freshreview/merge.

This is the sole selected next task under existing404; no new issue/speculative
backlog or independent disjoint readywriter. FullF20/liveQwen/deferred400 acceptance
remainsOPEN; marketplacegate/F23-last preserved. No owner-source/model/runtime/
install/download/stableapp/cloud/deployment effect. RequiredremoteCI/freshreview/
verifiedmerge gate completion of this investigation; claim retained through review.


### 2026-11-20 — manual-plan investigation merged; source manual-plan implementation started

PR805 fresh reviewed head28bb2f6306facedb8e1da4f32ddc9e26d475f4b1 protected squashmerge
0a22dbefa2e715202773ed924b2543d21bb4c19c verified by plugin main/mergedPR/issue404OPEN
and fetched exacttree48c02db2c7619e85706c46103efc8512dc8ca79e matching local9502ad1.
Full remote/localdiff/criteria/probe review no blockers, emptythreads, unchangedhead/
base/main. RequiredCI44770999964 Python136408308891/Flutter136408309593 every required/
poststep SUCCESS; completedlogs inspected fullFlutter/browserstorage/transport/
staticHTML/web/independentgeneratedFlutter/Python. Local27sourceprobes+legacyplan
checks PASS incl actual nativeDB/durableCAS. Investigation Done, no source-plan UI
or new authority claimed. Coordinator merge/outcome recorded, integration/claim
released; owner data/processes/stableapp preserved; fullF20/deferred400 remainOPEN.

Immediately claimed404-source-backed-manual-plan from verifiedmain in registered
issueworktree, solewriter. Scope store/controller/sourcepanel/workspace/manualplanview,
relevant plan/sourcecontroller/widget tests and canonicaldocs/inventory. Complete
outcome includes explicit source-text localstorage consent, currentcapture recheck,
manualdraft/save/reviewapproval/current-input/durableCAS/staleapproval behavior,
legacycompatibility and actual relevant fixture/UI/build/CI/review/merge gates.
No second independent disjoint readytask admitted.

Started ImportedPlanStore optional typed capturedSource alongside unchanged legacy
capturedDocuments; ambiguous simultaneous contexts reject. Shared read-only
capturedContext getter selects exact source identity for current-input checks and
save transaction snapshots, preserves default/document payload/key/record formats.
Controller exposes source/generic capture without changing existing document getter.
No source-panel or manualplanview callsite added yet, no automatic UI admission,
source read/write, model request, authoredplan generation or execution authority.

Initial25plan+1architecture PASS. New source tests cover draft-before-approve,
exactBOM/CRLF sourcecontext save/approve/reopen without recordmigration, ambiguous
context no-write refusal and changedsource identity preservingoldrawapprovedrecord
while current/activeapproval staysfalse (including failed reapproval before newdraft).
Legacy22plan/nativeDB/durableCAS regressions remainactive. Threefileanalysis clean;
inventory regenerated and9inventorychecks PASS. Logs
/tmp/asg404-source-manual-plan-start.log,
/tmp/asg404-source-manual-plan-start-analyze.log and
/tmp/asg404-source-manual-plan-start-inventory.log. Continue source storage-consent/
controller/view wiring and source-specific stale/disposal/requirements/nativeDB/
IABsynthetic/fullbuild/requiredCI/freshreview/verifiedmerge gates. Activeclaim retained.
FullF20/liveQwen/deferred400 acceptance pending; marketplacegate/F23-last unchanged.
No install/download/stableapp/cloud/deployment or owner-source effects.


### 20 November 2026 — source-backed manual-plan local delivery validation

Continued404-source-backed-manual-plan. Source panel exposes manualplan only from
fresh eligible capture and asks separate explicit local source-text/provenance
storage consent. Root/readset/metadata/requirements and controller ownership are
rechecked after dialog settlement before navigation. Cancel/changedselection/
changedrequirements refuses. ImportedPlanScreen renders literal source attribution
and historical storage/no-model/no-execution disclosure through typed capturedContext;
old document API/text/metadata/default record/key behavior retained. Plan save still
requires a current exact draft before reviewapproval; source snapshot follows all
transactional save/current-input/stale-record comparisons. No model call, authored
plan synthesis, sourcewrite/command or execution credential added.

Meaningful async regression found and fixed: an injected delayed conditional approval
commit could publish approved:true after its controller was disposed. Reproducer
/tmp/asg404-source-manual-plan-dispose-before.log failed on old behavior. Added optional
workflow authorization to store save, checked with input stability at the durable
conditional commit boundary; controller refuses authorization once disposed. New
regression now retains olddraft and reopenedapprovalfalse. The same guard protects
legacy plan workflows; preexisting storage formats are unchanged. Existing commits
already past authorization are not claimed reversible or cancelled.

Final51focused plan/sourcecontroller/sourcepanel/architecture PASS: legacy and
source save/draft/approval/reopen, ambiguouscontext refusal, stale source identity,
consentCancel/no-write, selection/requirements changes duringconsent, dispose-before-
commit and actual native sourceDBclose/reopen plus stale durableCAS. FullFlutter
2556PASS13explicit opt-in skips/analyze/inventory9/product32/616fileformat/web/native
build PASS. Full run preceded only one consentcopy grammar correction; finalpanel9
PASS and finalanalysis/format/inventory/mainweb/isolatedMac builds rerun unchanged
runtime hashreceipt. Two braceinfos corrected manually. Logs
/tmp/asg404-source-manual-plan-{focused,full,analyze-final,format-final,inventory-final,
product,panel-final,web-final,native-final}.log. Bundle
com.arsinha.asg.sourcemanualplanvalidation and exact sourcehelper/six runtime hashes
recorded/tmp/asg404-source-manual-plan-build-receipt.json; nativeUI not claimed.

IABsupplied-data fixture (synthetic source, memoryrecords; no model/files/commands)
verified read->localstorage consentCancel->explicitOpen->authoredSaveDraft(unapproved)
->separateApprove->return/reopen samecontext approved->changesavedrequirements->new
context olddraft retained/approvalinactive and approvalbuttonsdisabled. Fixturebuild
/tmp/asg404-source-manual-plan-browser-build.log; owned8398server stopped. No live
inference required or requested, owner runtime/processes/weights untouched. Required
remoteCI/fresh exactreview/verifiedmerge remain gates; fullF20/deferred400 OPEN.

Next eligible bounded F20/#404 prerequisite after verifiedmerge: inspect a read-only
source-edit proposal/diff boundary. Manual plan reviewconsent is not write/command
permission; inspect existing candidate/review models and imported workspace for a
concrete typed proposal identity/diff gap. Determine how a user-authored replacement
can bind exact selected source/root/context/currentmanualplan without modifying any
repository, running a toolchain or treating text as executable authority. Use pure/
disposable fixture checks, preserve legacy/fixed-candidate workflows and stale
approval/lastworking output; record one bounded implementation with acceptance in
REQUIREMENTS. Investigation scope canonicaldocs only, reuse404, no speculative queue
or independent disjoint readywriter. Marketplacegate/F23-last/approvallimits and
unavailableplatform400 unchanged. No owner-source/model/install/download/stableapp/
cloud/deployment effects; activeclaim retained through review.


### 2026-11-20 — source manual plans merged; proposal/diff boundary investigation started

PR806 fresh reviewed head5f142ed1b9e866014e049bc1d323e1fcc885b4c2 protected squashmerge
d1b7e62b77e3194e5af438e7d938b8a1e62056ae verified by plugin main/mergedPR/issue404OPEN
and fetched exacttree73678bbbddecc7dace97755e9443233a54e8be78 matching localdc06c5d.
Full12file remote/localdiff matched; source admission/legacyformat/currentdraft/CAS/
post-consent checks/disposed-owner authorization/literal review and real regressions
reviewed no blockers; emptythreads unchangedhead/base/main. RequiredCI44774964188
Python136422198362/Flutter136422197591 every required/poststep SUCCESS; completedlogs
inspected new source-consent/disposal/sourceDB/CAS and legacy/fullFlutter/browser/
transport/staticHTML/web/independentgeneratedFlutter/Python checks. Local51focused,
full2556PASS13explicit skips, finalpanel9/analyze/616fileformat/inventory9/product32,
web/isolatedMac/exacthelper/hashreceipt and IABsynthetic consentCancel/save(unapproved)/
separateApprove/samecontextreopen/changedrequirementsinactive PASS as above. Bounded
source-backed user-authored manual plans delivered; reviewapproval is not execution
permission. Coordinator merge/outcome recorded, integration/completedclaim released.
Ownerdata/processes/stableapp preserved; fullF20/liveQwen/deferred400 remainOPEN.

Immediately claimed404-source-proposal-boundary from verifiedmain in registered
issueworktree, solewriter, threecanonicaldoc scope. Read imported source/manualplan
and existing CandidateSourceProposal/CandidateSourceFile/ApprovedSourceProposal and
SourceLineDiff boundaries. Concrete gap: fixed candidate source path uses asg/lib
or asg/test rootprefix/stricter components, while imported source paths are relative
lib/test and can include supported dots/hyphens. Fixed candidate text caps16KiB/
500lines versus32KiB observed sourcefile. Do not silently prepend a directory,
truncate a capture, relabel it as a fixed candidate or inherit execution identity.

Started4pure probes plus existing candidateproposal/diff regressions:14PASS, incl
narrow320px/200percent review and Cancel no-write cases. Verified imported literal
pathsubset versus fixedcandidate refusal/prefix mismatch; fixed candidate exact16KiB
acceptance/32KiB and501line refusal; SourceLineDiff exact BOM/CRLF/missingnewline
reconstruction and immutable lines;300x300line comparison takes complete600row
coarse fallback beyond65536matrixcells rather than quadratic allocation, retaining
both before/after text. /tmp/asg404_source_proposal_probe_test.dart and
/tmp/asg404-source-proposal-start.log retain evidence. No model/source filesystem/
command/toolchain action or new production code added by investigation.

Continue current-plan/context/source identity and replacement validation/legacy
compatibility probes, then record one bounded read-only imported proposal/diff
implementation in REQUIREMENTS. Manual plan consent cannot authorize source writes,
commands or arbitrary execution. No independent disjoint readytask admitted;
marketplacegate/F23-last/unavailableplatform400 unchanged. No install/download/
stableapp/cloud/deployment effects. Activeclaim retained for continuation.


### 20 November 2026 — imported source proposal/diff boundary findings

Completed bounded investigation404-source-proposal-boundary. Seven pure disposable
probes plus existing candidateproposal/source-line-diff/imported-source-context
regressions:30PASS. Log/tmp/asg404-source-proposal-final.log; probe
/tmp/asg404_source_proposal_probe_test.dart. No production model/controller/UI or
storage change. Current fixed CandidateSourceProposal additionally binds snapshot,
Python/trusted-source/destination/runName; that transport is not an imported read-only
proposal contract. Do not coerce imported paths or inherit those execution identities.

Verified fixed candidate16KiB/500line policy differs from32KiB source observation;
fixed candidate validator also refuses BOM-prefixed text (UTF8 decode strips BOM),
whereas SourceLineDiff preserves original BOM/CRLF/missingnewline tokens and immutable
attribution. Unicode normalization differences retain different bytehashes; invalid
UTF16/NUL refuse fixed replacement validation. A new imported preview policy must
validate exact roundtripping text with explicit BOM preservation and reject oversize/
invalid text without normalization/truncation. Existing line-diff max65536matrixcells
coarse fallback can be reused as read-only comparison; verified complete before/
after reconstruction at300x300lines and existing narrow320px/200percent review.

Prototype canonical full ImportedPlan.toJson SHA shows changes to authored text,
context, approved flag or recordedAt each alter identity. Leaf filehash or context
hash alone cannot identify the reviewed plan. Controller/store must recheck current
app inputs and exact savedplan before publishing preview; rawapprovedtrue is not
source-write/command permission. Preserve fixed candidate and legacy plan workflows.

Next eligible coherent F20/#404 implementation after verifiedmerge: read-only
user-authored imported source proposal/diff review. New pure immutable proposal binds
root, exact ImportedSourceContext digest, canonical full approved-current-plan digest,
one literally selected captured lib/test path, before/after bytehashes and replacement
in a separate versioned source_verified=false identity (wholeUTF8 identity<=64KiB).
Require plan.context==capture.recordJson and reviewedplan flag, exact selected path,
changed replacement and bounded exact before/replacement text16KiB/500lines; retain
BOM/CRLF/Unicode distinctions, reject invalidUTF16/NUL/unsupported controls/oversize,
never truncate or prepend asg/. Empty replacement means proposed empty contents only,
never file deletion. SourceLineDiff comparison is display data, not an apply patch.

New feature controller/view prepares from fresh selected capture and current saved
sourceplan, rechecks root/metadata/requirements/exactplan before preview and marks
retained preview stale on changed inputs/failure. User chooses capturedfile and authors
replacement in transient UI, reviews literal before/after hashes/plan/context identity
and bounded/coarse diff. No new source-text persistence, model/toolchain request,
file read/write/delete, command, candidate publication or execution grant; existing
plan storage consent/approval limits remain. Reject stale/unapproved/mismatched/
corrupt/disposed/oversize inputs with retained draft/lastcomparison and privateerrors.
Focus pure identity/boundary/immutable plus controller/storage mismatch/widget/narrow/
IABsupplied-data checks, fullformat/analyze/tests/web/isolatedMac/requiredCI/freshreview/
verifiedmerge. Reuse404; this is the sole next task, no speculative/parallel queue.
FullF20/liveQwen/deferred400 remainOPEN; marketplacegate/F23-last unchanged. No owner-
source/model/install/download/stableapp/cloud/deployment effects. RequiredremoteCI/
freshreview/verifiedmerge gate investigation completion; activeclaim held throughreview.


### 2026-11-20 — proposal boundary merged; read-only imported proposal started

PR807 fresh reviewed headab8563bb8d87165f7e8ca09ddab783e922c1c3a5 protected squashmerge
039535cf80f42be49948b717dfd9782d269169c6 verified by plugin main/mergedPR/issue404OPEN
and fetched exacttreed8b0f0fe8204f7e67eda3954ad4d471dc2a45bac matching local0438680.
Full3doc remote/localdiff/criteria/probes review no blockers, emptythreads and unchanged
head/base/main. RequiredCI44777451763 Python136430939699/Flutter136430940218 every
required/poststep SUCCESS; completedlogs inspected fullFlutter/browserstorage/
transport/staticHTML/web/independentgeneratedFlutter/Python checks. Investigation30
pure/probe/candidate/diff/source-context checks PASS. Coordinator merge/outcome
recorded, integration/completedclaim released. No production proposal/writeauthority
or fullF20 acceptance claimed; ownerdata/processes/stableapp preserved.

Immediately claimed404-imported-source-proposal from verifiedmain in registered
issueworktree, solewriter. Coherent outcome includes pure proposal, readonly app-record
service/durable input fence, featurecontroller/view/source/workspace entry, private
stale/error/draft retention and actual relevant fixture/UI/build/CI gates. Scope new
model/service/controller/view/tests plus selected existing source UI/controller,
canonicaldocs/inventory; no independent disjoint readywriter admitted.

Started pure final ImportedSourceProposal. Separate versioned imported-source-proposal
identity binds exact root/contextSHA/canonical full reviewed-planSHA/selected relative
path/before-afterSHA/replacement, source_verified=false and64KiBwholeUTF8record bound.
Requires reviewedplan context equal to captured sourcecontext, selected literalfile,
changed replacement and before/replacement16KiB/500line exact text. Preserves BOM/CRLF/
Unicode bytes via strict roundtrip validation, refuses invalidUTF16/NUL/unsupported
controls/oversize privately with no truncation/pathcoercion. Empty replacement is
proposed empty contents only, no delete semantics. Immutable selected source and
SourceLineDiff remain transient review data, not apply patch/writegrant/currentdisk
proof. Current savedplan/app/durable input checks belong to pending service/controller;
this pure model alone does not establish current approval or source-write authority.

Initial4proposal+5existingdiff+1architecture checks PASS: exact BOM/CRLF before/after
reconstruction/hash/fullplan timestamp identity, immutable sourcebytes/difflines,
unapproved/wrongcontext/unselected/fixedprefix/unchanged private refusal,16KiB exact/
overflow/multibyte/500line/501line/surrogate/NUL/control validation and empty-content
proposal record with no execution transport. Two braceinfos corrected manually,
then twofileanalysis clean and10checks rerunPASS; inventory regenerated and9inventory
checks PASS. Logs/tmp/asg404-imported-proposal-start.log,
/tmp/asg404-imported-proposal-start-analyze.log and
/tmp/asg404-imported-proposal-start-inventory.log. Continue additional model identity/
beforelimit cases, actual savedplan/current-input/durable fence/controller/view and
IAB/fullrequiredchecks before review/merge. No service/UI/storage/model/file/toolchain
callsite added by this start. FullF20/liveQwen/deferred400 pending, marketplacegate/
F23-last unchanged; no owner-source/install/download/stableapp/cloud/deployment effect.
Activeclaim retained for continuation.


### F20 / #404 — transient imported-source proposal implementation, 20 November 2026

Continued owned404-imported-source-proposal in registered issue worktree. Added
read-only app-record selection/verification service, lifecycle-aware controller and
explicit captured-source/workspace entry to a transient replacement editor. Preview
requires the exact saved reviewed source plan, saved folder, metadata and requirements;
production conditional storage verifies durable expected inputs with zero updates.
Changed inputs require reload, never implicit rebase. Invalid drafts, changed plans,
failed verification and disposal retain prior comparison marked stale; editable draft
is retained. No proposal record, source write/read/delete, model, toolchain, command,
apply or execution grant. The existing manual-plan storage consent remains separate.

The screen selects only captured files, shows literal reviewed plan and identity hashes,
reuses bounded immutable SourceLineDiff, labels historical captured comparisons unverified
and exposes only Preview/Reload. A replacement may be empty contents, never file deletion.
Controller replacement resets view state and disposes the old owner.

Verification: 10 new controller/store/widget regressions PASS, including actual native
DB durable-plan change behind stale session cache, zero-update fences, immutable inputs,
unapproved/missing/corrupt plan refusal, delayed verify/disposal, changed saved plan,
invalid-draft retry/previous-output retention, narrow320px/textscale2 and screen disposal.
Existing proposal/source-panel/controller/architecture27 PASS; fullFlutter2570 PASS with
13 existing opt-in skips. Analyze clean;624formattedfiles unchanged;web build PASS;
isolatedmacOS Debug build PASS under com.arsinha.asg.sourceproposalvalidation without
install/launch/stable-app replacement. Six-runtime-hash receipt in
/tmp/asg404-source-proposal-build-receipt.json; native UI not verified. Inventory9 PASS.
IAB supplied-data fixture onowned8399 verified literal untrusted source display, authored
replacement/diff, oversize refusal with previous comparison stale and corrected retry;
preview server stopped after verification. No owner-source or live-model requests.
Logs/tmp/asg404-proposal-{new-tests,full,analyze,format,inventory,web,native,browser-build}.log.

Publication/fresh exact review/requiredCI/verifiedmerge pending at this checkpoint.
FullF20 and unavailable-platform#400 acceptance remain open; marketplace gate/F23-last,
Stop/recovery, approval and last-working-output boundaries preserved.


### F20 / #404 — verified PR808 and recovery prerequisite started, 20 November 2026

PR808 merged1fb3dfb6eedbf819be1a13c442da43e9b8e61c29 after fresh exact review of
remoted4f5b0bf2ca3afb94b50310f414452177d14195c against039535cf80f42be49948b717dfd9782d269169c6.
CI44782558188 Python136448790862/Flutter136448790440 all required and poststeps SUCCESS;
completed logs inspected. Plugin main/mergedPR/404OPEN and fetched merge/tree
77069c5d2fa4a35c6dbc0115ed4e8ad2072772ca verified equal to tested contents. Local
2570FlutterPASS/13opt-inskips, analyze/624format/web/isolatedMac/inventory9/product32,
IABsynthetic and two additional exact-model review probes passed (captured-before
16KiB/500line refusal; full-plan-text identity and complete600row coarse reconstruction).
The PR attachment tool was attempted and refused because this chat exceeds100attachment
identities; PR remains available at https://github.com/arpit-it/ASG/pull/808. No other
attachments removed. Coordinator recorded merge/outcome; completed claim/integration
released. Owner dirty main and owner processes preserved; owned8399server stopped.

Immediately claimed404-imported-proposal-recovery from verifiedmain in the same
registered worktree, solewriter, no independent ready disjoint task. Existing umbrella404
covers this F20 retain-history/reopen gap; no new issue. Read-only bounded investigation
owns only these three canonical documents, with disposable probes outside repo.
Acceptance: inspect existing proposal/source-context/plan/storage APIs; verify exact
historical reconstruction using full captured/reviewed-plan provenance, strict identity,
BOM/CRLF/limits/tamper and changed-current-plan examples; specify coherent bounded save/
reopen consent and conditional previous-working retention before implementation.

Concrete gap: current proposal identity deliberately stores root/context/plan/file hashes
and replacement, but no original source text or full reviewed plan; no decoder or proposal
persistence exists. Approved ImportedPlan.context retains source provenance only while
that saved plan survives; using a later plan would silently substitute historical inputs.
Existing advisory record/store offers strict bounded decode and conditional publication,
but cannot directly reconstruct a source diff or grant source/write/command authority.
Started recovery probes with existing factories and supplied data only. Production code
and storage semantics remain unchanged; fullF20/#400 pending, marketplace/F23 order intact.


Recovery start evidence: disposable/tmp/asg404_imported_recovery_probe_test.dart and
12 existing proposal/controller/native-store checks passed15total, log
/tmp/asg404-recovery-start.log. Full historical plan plus proposal identity reconstructs
exact BOM/CRLF source/replacement and hashes using existing public factories; changed
before text with old hash, changed replacement with old identity, or later reviewed-plan
substitution refuse. Original historical inputs remain reconstructable without source
reads. The small supplied envelope fits256KiB; this is not a proven universal whole-record
limit or a production decoder/storage implementation.

A naive RequirementsBoard.fromJson reuse initially failed two reconstruction probes:
existing captured default board revision0 is valid in source context, while the durable
board decoder requires revision>=1. The prototype recognizes only byte-equivalent
canonical empty default before using that durable decoder for other boards. It does not
change durable-board versioning or treat arbitrary revision0 input as an empty board.
Further nonempty-board/order/duplicate/whole-envelope limit and actual saved-record CAS/
reopen/disposal cases remain for this claimed investigation. Future storage must retain
full original reviewed-plan/context provenance, distinguish historical comparison from
current approval, require explicit local source/replacement storage consent, strictly
revalidate all identities and keep previous output on conflict/failure. No proposal save
or executable export exists yet. Active investigation retained; no completion claim.


### F20 / #404 — imported proposal recovery investigation findings, 20 November 2026

Completed bounded local prerequisite investigation404-imported-proposal-recovery.
Six disposable recovery probes plus existing pure proposal/controller/native-store/manual
plan regressions passed46total, log/tmp/asg404-recovery-final.log. Supplied BOM/CRLF
before/after identity reconstructs through existing observation/context/proposal factories
when the complete original reviewed plan is retained. A nonempty saved requirements board
at revision3 reconstructs without changing its revision or contents. Exact canonical empty
revision0 must be handled separately; arbitrary revision0 records must not be coerced to
empty or passed through durable-board revision rules. This investigation changes no app
runtime, storage format, durable-board versioning or source permissions.

Bounded temporary envelope probe refuses duplicate/escaped duplicate members, unknown
fields, oversize>256KiB, tampered captured text with old hash, changed replacement with old
identity and substituted later reviewed plan. Historical reconstruction uses original
provenance, not current plan substitution; comparison remains source_verified=false.
The small fixture fits256KiB; the future writer must refuse larger complete envelopes
before publication rather than promise every preview can be saved or truncate data.
Prototype is disposable feasibility evidence, not a production decoder or saved-proposal
feature; production needs exhaustive field/type/member/UTF8/byte/hash checks and private
errors, including malformed/deep/nested JSON, field/selection order and unsupportedschema.

Actual owned native DB probe verifies the proposed new studio.importedSourceProposal.v1
key is currently unsupported and refused before any update; prior approved plan bytes
survive. A direct durable plan change behind the app cache then causes the existing
zero-update conditional fence to refuse, and separately reopened DB retains that later
plan and no proposal record. This proves the registration prerequisite and current fence,
not a production proposal save/reopen or CAS implementation. Temporary DB closed/deleted;
no owner source/model/toolchain/commands/stable app effects.

Next bounded implementation after verified investigation merge: explicitly save/reopen
one last working historical imported-source comparison with local-storage consent. Add a
strict immutable <=256KiB record containing full canonical reviewed plan (including source
context) and proposal identity; reconstruct exact source/diff and verify all hashes. Use a
new dedicated versioned per-folder key registered in StudioDatabase with key/root identity
validation and no change to existing keys/formats. Save only the exact current nonstale
preview after consent and durable expected folder/requirements/current-plan/previous-record
CAS; validate again at commit and stop late disposed work. Failed/conflicting/corrupt saves
retain prior bytes, draft and previous comparison, with explicit unchanged retry when safe.
Reopen must show historical provenance independently from current saved plan, never revive
current approval, auto-preview/rebase/apply, read/write source, or invoke model/commands.
Cover pure decode/tamper/bounds/BOM/CRLF/revision0+nonempty boards, actual DB reopen/CAS,
failed-save/disposal races and narrow/IAB explicit save consent/reopen/failure recovery,
then format/analyze/fullFlutter/web/isolatedMac/inventory/requiredCI/freshreview/verifiedmerge.

Investigation publication and protected merge remain pending at this checkpoint. Reuse
umbrella404; no additional issue/backlog. FullF20/CE01 and unavailable-platform400 remain
pending; marketplace gate and F23-last ordering unchanged. No second ready disjoint writer.


### F20 / #404 — verified recovery investigation and save/reopen implementation started, 20 November 2026

PR809 verified merged1a3ce55329a61803d3f1877d3cab96ae90fc00c6, tested/inspected tree
bc72b25e08e30176ed48b4ef05b7b65594cb5df6. Fresh exact review covered remote
f94e40fc5a12b24bb1a12ce4e154a054ca2032e9 against1fb3dfb6eedbf819be1a13c442da43e9b8e61c29;
remote/localdiff match, no blocking findings, empty review threads, unchangedhead/base.
CI44785205263 Python136458106500/Flutter136458106024 all required and poststeps SUCCESS;
completed logs inspected. Pluginmain/mergedPR/404OPEN and fetchedmain/tree verified.
Coordinator recorded checks/review/merge/outcome and released completed integration/claim.
Attachment was attempted but the chat exceeds100attachmentidentities; no attachments
removed. Forty-six local investigation/relevant regressions passed; no runtime change
was included in that investigation. FullF20/CE01 and unavailable-platform400 remain open.

Immediately claimed404-saved-imported-proposal from verifiedmain in the same registered
worktree, solewriter; no independent ready disjoint task. Existing404 umbrella covers
explicit local save/reopen of one last working historical comparison. Scope new strict
record/context restore, existing proposal store/controller/view, StudioDatabase registration,
related model/store/controller/widget/database tests and canonical docs/inventory.
Acceptance: complete original canonical reviewed-plan/source/proposal provenance in a
strict immutable <=256KiB record; explicit captured-source/replacement storage consent;
current nonstale preview and durable folder/requirements/current-plan/previous-record CAS;
commit-time input/alive guards, failed/conflicting/corrupt/disposed retention and safe
explicit retry. Reopen historical comparison independently from current plan, without
reviving approval or auto-preview/rebase/apply/source reads/writes/model/commands.
Full regression/build/IAB/CI/freshreview/verifiedmerge belongs to this coherent feature,
not a model-only delivery. Preserve existing record schemas/keys and dirty owner checkout.

Started pure ImportedSourceContext.restore and ImportedSourceProposalRecord. Context
restore checks canonical exact field/selection identities, duplicates, string scalar
validity,32-level decoded structure, typed metadata/files/requirements, original source
UTF8 byte/hash constraints and existing128KiB evidence cap. Exact canonical empty default
revision0 is separate from nonempty durable-board revision>=1; no coercion/versionchange.
Historical record retains full reviewed plan/source context, exact proposal identity and
UTC recorded time, verifies root/full-plan/source/before-after/proposal identities by
reconstruction, enforces256KiB whole record and64KiB proposal bound, and rejects
noncanonical/malformed/duplicate/unknown/tampered/invalid-scalar inputs with private errors.
Data remain immutable/unverified and confer no current approval or transport authority.
No storage registration/save/controller/UI callsite added by this start.

Six new record/context regressions plus existing pure proposal/source-context/architecture
checks passed24total: exact BOM/CRLF roundtrip/immutability/fullplan identity, nonempty
revision3 board and selected-file order, unpaired reviewed-plan/source/metadata scalar
refusal, unknown/duplicate/escapedduplicate/noncanonical/oversize envelope, root/plan/
source/replacement/time tampering and deep context refusal. Analyze clean; focused Dart
files formatted. Inventory regenerated for changed runtime. Logs
/tmp/asg404-saved-proposal-start-tests.log and
/tmp/asg404-saved-proposal-start-analyze.log. Database/CAS/disposal/save-consent/reopen
workflow, widget/IAB/fullchecks remain pending under active implementation claim.
No owner-source/model requests, installs/downloads/stableapp/cloud/deployment effects;
marketplacegate/F23-last and existing Stop/recovery/last-output boundaries unchanged.


### F20 / #404 — saved imported-source comparison implementation, 20 November 2026

Completed coherent save/reopen workflow on404-saved-imported-proposal. Ownership was
explicitly expanded before adding the necessary workspace history entry: released the
original404-saved-imported-proposal claim, preserved existing wiring in checkpointc7239dd
when clean admission was required, then claimed404-saved-imported-proposal-flow with the
same outcome plus workspace/view regression paths. No edits in expanded paths preceded
that claim; no abandoned work, unrelated files or remote effects discarded. Solewriter,
serialized publication; original models started in85754bc remain part of this feature.

Explicit Save comparison locally consent describes storing all captured source, full
reviewed plan and replacement, replacing this folder's last saved comparison,256KiBtotal
limit and no source/write/model/execution grant. New versioned per-folder app key is
strictly validated by StudioDatabase, including key/root identity. Corrupt history is
retained as an unreadable record without blocking unrelated app records or being treated
as absence. Durable expected folder/requirements/current-plan/previous-record CAS and
commit-time alive/input checks protect publication. Failure/unknown confirmation keeps
editable draft and previous comparison; unchanged retry is explicit and revalidates.
Already-authorized durable commits are not claimed undoable by later disposal.

History-only workspace entry and controller mode reopen app records without any source
capture, current plan or model/host action. Reconstructed original source/diff/plan remain
historical/unverified, separate from current approval; no automatic rebase/preview/apply.
Editor can open prior history independently of current planning success. New context/
record models preserve canonical bytes/hash/order/BOM/CRLF/defaultrevision0/nonemptyboard
identities and refuse unsupported/corrupt/duplicate/oversize inputs privately.
Existing keys/formats and manual-plan consent remain unchanged. No source-file writes,
deletes, execution, executable export, model requests or external data-sharing consent.

Tests exposed and corrected two implementation defects before publication: new corrupt
history initially escaped the database's per-record unreadable handling; registration now
preserves its bytes while other records open. A new mutable-caller expected-input race
reproducer failed before the fix and passed afterward: store.save now freezes expected
inputs at invocation, so mutation during a pending transaction cannot authorize overwrite
of an external winner. Logs/tmp/asg404-saved-proposal-mutable-{reproducer,fixed}.log.
Neither defect was published or an escaped user defect; the final revised source was
retested and rebuilt. The UI consent was also made explicit about the whole-record limit.

Validation:58focused workflow/model/nativeDB/widget/workspace/legacy-plan/architecture
checks passed before final snapshot fix; the final store5/regression and complete suite
passed afterward. Final fullFlutter2587 PASS/13 existing opt-in skips; analyze clean;
627formattedfiles unchanged; inventory9/product32 PASS. Web and isolated macOS Debug
builds PASS under com.arsinha.asg.savedproposalvalidation, with no install/launch or stable
app replacement. Seven-runtime-file hash receipt and exact packaged source helper in
/tmp/asg404-saved-proposal-build-receipt.json; native UI not verified. Final logs
/tmp/asg404-saved-proposal-{full,analyze,format,inventory,web,native,browser-build}-final.log;
focused log/tmp/asg404-saved-proposal-focused.log, product log
/tmp/asg404-saved-proposal-product.log. No live inference was needed or claimed.

IAB supplied-data fixture onowned8400 verified consentCancel->emptyhistory, confirmed
save, failure retaining firstsavedcomparison+secondeditable draft, explicit retry success,
then history-only reopen after current plan removal. Literal untrusted source/link text
and original historical plan displayed without action; synthetic capture count remained1,
no new source/model/command request. Preview server stopped after verification. This is
injected browser evidence plus separate actual native database save/reopen/CAS/corruption
checks, not a claim of native device UI or owner-repository access.

Publication/fresh exact review/requiredCI/verifiedmerge remain pending at this checkpoint.
FullF20/CE01 and unavailable-platform400 acceptance stay open; marketplacegate/F23-last,
Stop/recovery and last-working-output limits preserved. Next concrete prerequisite after
verified merge is a bounded saved-baseline recapture investigation: compare all original
selected source bytes against an explicitly consented fresh contained read, including
changed/missing/refused observations, without source writes or execution authority.


Fresh PR810 review added the missing controller-replacement consent regression before
approval: replacing the editor with a history-only controller while its save dialog is
open disposes the original owner, and confirming old consent writes to neither folder.
All5 proposal screen checks and the revised fullFlutter2588 PASS/13opt-inskips;
analyze and627format clean. Logs/tmp/asg404-saved-proposal-review-{widget,full,analyze,format}.log.
This is a test/documentation-only forward revision; all seven runtime hashes match the
verified web/isolatedMac/IAB build receipt exactly. Prior head review/CI evidence is not
used to merge the changed revision: final exact rereview and required CI must pass anew.


### F20 / #404 — verified PR810 and baseline-recheck investigation started, 20 November 2026

PR810 merged9b79c589ecf0437aa0a3209ac855a86bac9b6f8d; tested/reviewed tree
2180eaf665b9eb04002ac30be600160d7a973f2f. Final fresh review covered remote
b304125959bdb811ac7ebe30182703c754a7f5ad against1a3ce55329a61803d3f1877d3cab96ae90fc00c6,
including the forward controller-replacement consent regression. Required final
CI44791372615 Python136479742131/Flutter136479741340 all required and poststeps SUCCESS;
completed logs inspected, exact remote/local diff matched, no blocking findings, empty
threads and unchangedhead/base/main verified before protected merge. PriorheadCI was not
used for revised-head approval. Pluginmain/mergedPR/404OPEN and fetchedmain/tree verified.
Final localfull2588 PASS/13 existing opt-in skips, all5 screenchecks/analyze627format/
inventory9/product32 and matching7runtime-hash web/isolatedMac/IAB evidence recorded.
Coordinator recorded checks/review_changes/review/merge/outcome, then released completed
integration/claim. Its durations are cooperative continuation-track/manual observations,
not total feature or provider CI timing; unknown escaped-defect counts remain unknown.
Owner dirty checkout/processes preserved; owned8400preview stopped. FullF20 remains open.

Immediately claimed404-saved-baseline-recheck from verifiedmain in the same registered
worktree, solewriter, no independent ready disjoint task. Existing404 covers the concrete
F20 stale-baseline gate before future imported source edits; no new issue. This bounded
investigation owns only these three canonical documents and uses disposable probes.
Acceptance: inspect saved-proposal/context and existing request/observation/controller/
native host/helper; compare every original selected file's root/readset/order/path/bytes/
hash against an explicitly consented fresh contained observation. Cover unchanged BOM/
CRLF/multibyte data, changed target or another captured file, missing/refused/unsafe
observations and mismatched readsets; preserve saved records. Use existing trusted helper
fixtures only on newly owned temporary folders, with no owner-source/model requests.

Started by tracing a concrete attribution boundary: source observation schema contains
selected_paths/files/status but no root. A future comparison must bind the frozen fresh
request.root to the saved record.root as well as exact selected paths; payload hash equality
alone cannot establish requested-folder provenance. Existing request freezes selected
paths and the native host owns trusted packaged-helper arguments/cleanup. A point-in-time
byte match must remain source_verified=false, never revive historical plan approval or
close the TOCTOU gap for a later write. Current app-plan checks, explicit fresh-read consent,
Stop/disposal/cleanup and any future editing authorization remain separate prerequisites.
No production baseline-check/apply/source-write workflow is added by this investigation.


Baseline investigation start:6 disposable comparison probes plus19 existing historical
record/source-context tests passed25total, log/tmp/asg404-baseline-pure-start.log;
31 existing descriptor-contained source-reader fixtures passed on this Mac, log
/tmp/asg404-baseline-reader-start.log. The native fixtures use newly owned temporary
source folders, not owner repositories. Supplied comparisons preserve exact BOM/CRLF
bytes and saved record identity; changed target or peer file, wrong frozen request root,
subset/reordered readset and missing/unsafe/changed/unavailable observations refuse.
A matching historical byte observation can coexist with a later unreviewed current plan:
it establishes neither current approval nor source_verified=true. Disposable comparison
code in/tmp/asg404_saved_baseline_probe_test.dart is not a production app baseline gate.

Current gaps for this active investigation: actual app fresh-read consent and lifecycle/
selection/root/current-plan/requirements changes while read is pending, owned worker
cleanup/Stop, and independently bound new native observation evidence must be resolved
before choosing the next coherent baseline-check workflow. Point-in-time equality still
does not authorize or make a future write race-free. No production code or saved records
changed in this investigation; no model/source-write/execution/install/deployment effect.

Coordinator report for completed404-saved-imported-proposal-flow records continuation
start-to-merge1935.4seconds and paired CI-observation wait532.1seconds, one review rework
observation and one verified user outcome. These are cooperative manual observations for
that continuation segment, not provider CI timing or whole-feature elapsed time. Zero
recorded escaped-defect observations is not evidence that none exist; actual unknown
counts and earlier model-start duration remain unknown. Active baseline investigation
claim retained for continuation; no completion or new app capability claimed.


### F20 / #404 — saved baseline recheck investigation findings, 20 November 2026 UTC

Completed bounded404-saved-baseline-recheck prerequisite investigation. Eleven disposable
pure/lifecycle/native probes plus existing source-controller/host/observation/historical
record/store regressions passed69total, log/tmp/asg404-baseline-final.log. Earlier31
contained-reader fixtures passed separately; no aggregate app capability is inferred.
Actual Mac packaged-helper bytes matched trusted source SHA256
073b8f2addc76592aa2a19906f1461a92264641248641fdcecceb9cc037a0c13. Six independent owned
contained reads captured two temporary files, matched unchanged BOM/CRLF/café bytes,
detected peer and target changes, refused missing invalid/source_missing and symlink
unsupported/unsafe_source, and retained original historical record bytes/digest. Receipt
/tmp/asg404-baseline-native-receipt.json binds helper hash, supplied root/selected paths,
observation statuses/file hashes and original record identity. Source folder and helper
jobs were closed/removed; no owner-source/model/readback app record changed.

The first native probe incorrectly expected missing source to be unavailable; it was
corrected to the helper's actual invalid/source_missing protocol and all cases reranPASS.
This was a probe expectation, not a production defect. Fresh observations remain
source_verified=false. Comparison feasibility in/tmp/asg404_saved_baseline_probe_test.dart
requires frozen request.root == saved root and exact full readset/order/path/length/hash/
text/bytes. Matching hashes from a differently requested root, subsets, reordered readsets
and changes to another captured file refuse. Neither a matching baseline nor an old
historically reviewed plan establishes current approval, whole-repository freshness or a
race-free future write; frozen request provenance is necessary because payload omits root.

Existing native host validates canonical absolute root/Python outside project, loads only
packaged helper into a private owned directory, launches argument-vector -I/-S/-B without
shell/parent environment, bounds output/deadline and owns kill/reap/nonrecursive cleanup.
Stop/late startup/cleanup uncertainty guards are covered by current host/controller tests.
A result is not reusable until owned cleanup confirms; uncertain cleanup blocks overlap.
The manual ProjectSourceController is intentionally only a data reader: four pending-read
probes demonstrate that requirements/plan/saved-comparison/runtime-setting record changes
do not turn that reader into a frozen saved-baseline admission guard. It publishes captured
untrusted data without changing app records or granting approval. This is an integration
gap for the new workflow, not a regression in the manual-reader contract.

Next coherent implementation after verified investigation merge: explicitly recheck all
selected files of one saved comparison through the existing contained native reader.
Add a pure immutable comparison binding saved-record identity and frozen root/readset/
request/observation identities; label point-in-time match/change/refusal and keep
source_verified=false. Add read-only app-record selection/durable zero-update fences for
saved folder/current saved record/requirements/current plan/runtime settings; require
unchanged expected inputs before consent/dispatch and after owned cleanup before result
publication. Historical comparison is allowed without reviving current approval; current
plan/requirements identity is a separate frozen guard, never inferred from matching bytes.

Use one owned host job, explicit root/paths/Python read consent, generation/disposal/Stop/
late-result guards and sticky uncertain-cleanup exclusion. Keep previous comparison/result
stale on cancellation/refusal/failure; do not rewrite saved history or automatically rebase,
apply, verify a build, share with a model or execute project commands. Provide a history
entry/recheck view with current limits and unsupported-host states. Cover pure identities/
allreadset/refusals, durable stale-cache app fences, confirmation changes and delayed
cleanup/disposal, real owned Mac read matrix and injected IAB/narrow UI, then required
format/analyze/fullFlutter/web/isolatedMac/inventory/CI/freshreview/verifiedmerge. No new
source-write, Git or execution permission is part of this next slice.

Investigation publication/fresh exact review/requiredCI/verifiedmerge remain pending.
Reuse404umbrella; fullF20/CE01 and unavailable-platform400 remain open. Marketplacegate/
F23-last unchanged. No independent ready disjoint writer or owner process change.


### F20 / #404 — verified PR811 and baseline-check implementation started, 20 November 2026 UTC

PR811 verified merged4e091c86e50247af0d3d07bd9dba19c3622f359a; inspected tree
f6d29aa7292c1496f9476a29f79aaaa94abdb2a9. Fresh exact review of remote
02ecdbf24af6ad093caf9eb2fa4b7460d9d84dff against9b79c589ecf0437aa0a3209ac855a86bac9b6f8d
matched remote/localdiff, found no blocking issues or review threads and retained the
fixture-versus-product distinctions. CI44794707013 Python136491111769/Flutter136491112241
all required and poststeps SUCCESS; completed logs inspected. Pluginmain/mergedPR/404OPEN
and fetchedmain/tree verified. Coordinator recorded checks/review/merge/outcome then
released completed integration/claim.69focused/31readerfixtures/six actual owned Mac
observations establish the investigation findings, not a delivered app baseline action.

Coordinator investigation-segment observations: start-to-merge1276.6seconds, paired CI
observation wait544.1seconds, zero recorded review rework and one outcome-verification
attestation. These manual/cooperative intervals and investigation tally are not provider
CI timing or a new user workflow; escaped defects remain unknown despite zero recorded
observations. Owner checkout/processes unchanged; fullF20/CE01 and unavailable-platform400
acceptance remain open, marketplacegate/F23-last preserved.

Immediately claimed404-imported-baseline-check from verifiedmain in same registered
worktree, solewriter, no independent ready disjoint task. Coherent outcome: explicitly
recheck all selected files of a saved comparison with historical records preserved and
point-in-time match/change/refusal distinct from current approval. Scope new pure model,
read-only record/fence/reader service, controller and focused view, history/workspace
entry wiring, related tests and canonical docs/inventory. Freeze saved folder/record,
requirements/current plan/runtime configuration; verify durable zero-update inputs before
consent/dispatch and after owned cleanup. Explicit root/all-paths/Python read consent;
owned read lease must survive view recreation until cleanup confirms, with Stop/disposal/
late-result/uncertain-cleanup guards and stale previous-result retention. No source writes,
model sharing, approval revival, executable export, automatic rebase/apply or commands.
Final coherent feature needs actual native/IAB/narrow/fullregression/build/CI/freshreview/
verifiedmerge; this model-only start is not published as a completed user capability.

Started pure immutable ImportedSourceBaseline with matched/changed/refused status,
all-selected-file before/after hashes/byte counts and exact byte/text equality, explicit
saved-record/request/observation identities, UTC observation time and bounded16KiB
identity record. Binds frozen root and complete selected-path order to original saved
context; lexical canonical absolute root/Python-outside-project checks reject malformed,
inside-project, unpaired-scalar and oversized requests privately. Existing native service
must still validate physical root/interpreter and own actual reads. Refused observations
never invent fresh hashes; changed peers cannot be ignored just because target matches.
source_verified remainsfalse and there is no current-approval/write/execution field.
No storage/host/controller/UI callsite is added by this start.

Five new baseline regressions plus existing historical record/source-observation/
architecture checks passed20total, analyze clean after two styleinfos corrected manually,
focused files formatted and inventory9 PASS. Logs/tmp/asg404-baseline-implementation-
{start,analyze,inventory}.log. A separate actual owned Mac six-read matrix against the new
production model also passed, log/tmp/asg404-baseline-model-native-start.log; independent
receipt/tmp/asg404-baseline-model-native-receipt.json records helper/driver/model hashes,
original record identity and observation statuses. Its temporary root was removed and
source_verified stayedfalse. No owner-source or model request.

Artifact limit: the first new-model fixture rerun regenerated the investigation's rolling
/tmp/asg404-baseline-native-receipt.json path; its original per-root receipt metadata is no
longer available there. PR811 and original test log retain the reported checks/helper
identity, but that rolling artifact must not be reused as original per-root proof. The
new-model fixture now writes its distinct receipt above; fresh roots/events are independent
observations, not replacements for earlier identities. No saved app record or last working
user output was overwritten. Remaining service/controller/consent/lease/native-app/IAB/
fullchecks are pending under the active implementation claim.


### F20 / #404 — saved source baseline recheck workflow, 20 November 2026 UTC

Completed the coherent local baseline-check implementation: saved comparison history
opens a focused explicit-read screen; no read occurs on navigation or cancelled consent.
The immutable comparison binds saved record, frozen root/Python/full ordered readset,
observation identity and time, and every selected file's before/observed hashes and bytes.
Changed peers are detected even when the proposed target still matches. Match/change is
a transient unverified observation, never current approval or a later write grant.

Read-only selection freezes folder references, requirements, current plan, saved history
and runtime configuration. Durable zero-update expected-input checks run before consent,
before dispatch and after owned cleanup before publication. Current plan may be absent
or unapproved; historical approval is not revived. A shared-record-store reader lease
blocks recreated controllers until owned cleanup and pending consent/read settle; sticky
cleanup uncertainty blocks reuse. Stop/disposal/late results/refusals retain the previous
comparison as stale. No saved-history writes, source writes, model requests or commands.
Lease exclusion is in-process per shared RecordStorage, not a crash/cross-process claim.

Validation: 27 focused tests and full Flutter 2613 PASS / 13 existing opt-in skips; analyze
clean, 635 formatted files unchanged, inventory9/product32 PASS, web and isolated macOS
builds PASS. Logs /tmp/asg404-baseline-flow-{focused,full-final,analyze-final,format-final,
inventory-final,product,web-final,native-final,browser-build-final}.log. Production native
DB tests cover stale durable changes behind cache for all five keys. Actual Mac controller/
DB/packaged-reader flow on owned temporary files matches BOM/CRLF/café, detects changed
peer, refuses missing invalid/source_missing, retains stale working result and preserves
all physical app records and original target bytes. Temporary root removed, lease released.
Independent evidence /tmp/asg404-baseline-flow-native-7700d2b84dd0add3546cc7237ba802f49f38932f9d9b71dc081d98fde193c314.json
binds six runtime hashes and helper SHA256073b8f2addc76592aa2a19906f1461a92264641248641fdcecceb9cc037a0c13.
The committed native regression does not write a shared rolling evidence file; retained
fixture evidence is distinct from future test roots. Recheck after that test-only cleanup
is recorded separately below.

IAB injected fixture verified Cancel/read0, matched/read1, changed peer/read2, missing
refusal/read3 retains changed/stale, Stop of delayed read/read4 retains stale, and app-plan
change during read/read5 rejects publication. Baseline writes remain0 and saved history
unchanged throughout; one intentional fixture app edit is not a baseline write. UI states
show all selected paths, point-in-time statuses, before/observed hashes and no new approval.
Owned port8401 server stopped. /tmp/asg404-baseline-flow-build-receipt.json binds runtime
hashes, packaged helper and isolated bundle com.arsinha.asg.baselinecheckvalidation.
No installed/stable app replacement or native GUI claim; modelRequests0. Browser display
is injected transport evidence; actual Mac contained read is independently exercised above.

Widget consent tests initially waited for settling while the deliberately busy progress
indicator remained active; finite dialog pumping fixed that test harness, then all5 passed.
Manual style fixes resolved analyzer infos. Required CI, exact fresh review and verified
merge remain pending. FullF20/CE01, unavailable-platform #400, marketplace gate and F23-last
remain unchanged; no independent eligible disjoint second writer was identified.


Final test-only receipt cleanup retest: full Flutter2613 PASS/13 existing opt-in skips,
analyze clean, inventory9 PASS and635format unchanged. Logs /tmp/asg404-baseline-flow-
review-{full,analyze,inventory,format}.log. All six production runtime hashes still exactly
match the verified web/isolatedMac/native-flow/IAB receipt; no runtime changed after those
checks. Local diff/whitespace review found no additional blocking issue. Publication and
fresh exact remote PR review/requiredCI/verifiedmerge remain pending.


### F20 / #404 — verified baseline recheck and snapshot admission investigation started, 20 November 2026 UTC

PR812 verified merged a49895b562f5e570f3e2d1dc2596e022902f3310; exact tested/reviewed
tree bcb1fa5c95d9d8493bfaa1a61c36d974b31b3f07. Fresh review remote7ae41870e54d8d881ecdc07ca6b706bcd35f0354
against4e091c86e50247af0d3d07bd9dba19c3622f359a matched remote/localdiff; no blocking
findings or review threads. Required CI44802431582 Python136517726157/Flutter136517726031
all required and poststeps SUCCESS; completed logs inspected. Pluginmain/mergedPR/404OPEN
and fetchedmain/tree verified. Coordinator recorded checks/review/merge/outcome, released
integration and completed claim. Full2613FlutterPASS13existing skips, analyze635format/
inventory9/product32, web/isolatedMac/nativeDB-reader/IAB evidence remains explicitly
scoped. No owner-source writes/model requests/nativeGUI/install/deployment claim. Owner
dirty checkout and processes preserved; attempted PR attachment hit existing100item limit,
so PR remains accessible by its normal URL without deleting unrelated attachments.

Immediately claimed404-imported-snapshot-admission from verifiedmain in same registered
worktree, solewriter; no independent eligible disjoint second task. Existing404umbrella
covers this concrete F20 prerequisite, no new issue. Bounded investigation owns only these
three canonical documents, with disposable Mac probes outside repository. Acceptance:
trace imported saved context/proposal/baseline versus generated/self snapshot admission;
prove selected-file match does not establish complete-repository freshness, and partial
selected manifest cannot be substituted into generic candidate preparation. Check a full
synthetic-manifest control into a new owned destination with original preserved; compare
imported path/empty-content/byte semantics against old fixed contracts. Determine exact
next candidate-copy prerequisites without treating history/current plan/byte equality as
write or command consent. No owner repository scans/copies, hooks/submodules, source
writes, model requests or project execution. FullF20/CE01 and unavailable-platform400
remain open; marketplacegate/F23-last unchanged.

Initial read-only code trace: imported baseline reads at most four selected lib/test Dart
files and has no whole-tree manifest. source_candidate_native._capture visits its input
project and rejects unrecorded source entries; GeneratedProject.sources is a closed
manifest belonging to a generated snapshot. The self-candidate helper instead reads a
selected immutable Git commit tree with distinct mode/path/blob/destination/Git-metadata
contracts; neither contract is imported write authorization or dirty/untracked capture.
A future imported candidate needs separate bounded source-snapshot selection/provenance,
explicit copy/write consent, current app-input/plan binding and owned destination/cleanup
policy before any runnable-project or branch/edit/test acceptance. A successful selected
recheck cannot supply missing unselected files or prove a later race-free write.


Snapshot admission start: three disposable characterization probes plus10existing generic
candidate regressions and5baseline model tests passed18total, log
/tmp/asg404-snapshot-admission-byte-start.log; earlier two probes+10regressions passed12,
/tmp/asg404-snapshot-admission-start.log. Actual packaged Mac reads demonstrated unchanged
selected main/peer can yield a matched unverified baseline while an unselected source file
changes. Passing only selected hashes to generic prepareCandidateFiles refused unrecorded
entries before creating output. A complete four-file synthetic manifest control copied
replacement and unchanged/changed peer contents to a newly owned destination, preserved
original bytes and removed all owned fixture roots afterward. This exercises generic helper
behavior under a fixture callback, not real imported copy/write authorization or an app UI.

Additional byte/path findings: imported hyphen/dot path policy and empty replacement
cannot silently map to older SourceEditProposal validation. A full generated manifest
with a BOM-prefixed target and exact original BOM bytes refused before output because
the generic candidate before-text decoder strips BOM. Imported observation/proposal
semantics preserve those bytes; direct wrapping is incompatible. Original BOM/café/CRLF
bytes and destination emptiness were asserted. This characterization adds no production
change or widening of generated/self contracts. No arbitrary commands/builds, model or
owner-source accesses occurred. Remaining investigation: bind imported root/readset to
an explicitly selected complete snapshot/commit and characterize dirty/untracked/conflict
inputs and destination/provenance admission before choosing a copy workflow. No current
approval, full-repo freshness, source apply or runnable imported project is established.

Coordinator report for completed baseline workflow: recorded start-to-merge2947.3seconds,
paired CI observation wait503.8seconds, zero recorded review rework and one verified user
outcome. These are cooperative/manual segment observations, not provider CI timing or
whole-product throughput. Zero recorded escaped-defect observations does not prove none
exist; actual escaped defects remain unknown. Next investigation claim retained for
continuation; fullF20/CE01 and unavailable-platform400 remain open.


### F20 / #404 — imported snapshot admission investigation findings, 20 November 2026 UTC

Completed bounded local admission investigation. Four new disposable Git/reader/snapshot
probes passed, log/tmp/asg404-snapshot-git-admission.log. Existing immutable snapshot44,
command-free HEAD metadata33 and selected-source31 Python regressions passed separately
(logs/tmp/asg404-snapshot-existing-{candidate,git,source}.log). Prior18Flutter checks covered
selected-source matching/partial-manifest refusal/full synthetic copy control and imported
path/empty/BOM compatibility. These are prerequisite observations, not a new app copy flow.

Actual newly owned Git fixture outcomes: dirty selected BOM/café/CRLF working bytes can
be captured while HEAD still declares a different immutable commit blob; an untracked Dart
file remains in the original and is absent from the commit snapshot. A dirty unselected
file leaves the two selected captures identical but the commit copy contains the earlier
committed unselected bytes. An explicitly constructed unmerged three-stage index reports
UU through bounded fixture Git status, while command-free HEAD metadata still says
working_tree/ahead_behind/conflict unknown. The trusted self snapshot helper exports the
chosen commit regardless of that conflicted index, preserves index/original bytes, and
produces no .git directory. This is correct immutable-commit behavior, not permission to
discard dirty work or represent that copy as current working content. A synthetic Git-link
entry is refused before output; no submodule operation, hooks, filter or remote command
was run. All fixture roots removed. No owner repository was read/copied by these probes.

The generic generated helper requires a complete generated manifest and cannot serve
as imported admission: selected files omit other repository content, imported hyphen/dot
paths and empty replacement are incompatible with older fixed proposal validation, and
BOM-prefixed original text is not preserved by its before-text comparison. Keep those
existing contract limits; do not silently broaden them or relabel saved context as a
GeneratedProject. A selected working baseline match grants neither whole-tree provenance
nor current plan/write/execute permission. HEAD declarations cannot certify dirty/conflict
state, object existence or selected commit contents. Unavailable-host acceptance400 and
fullF20/CE01 remain open; marketplacegate/F23-last unchanged.

Next coherent prerequisite implementation after this investigation's reviewed verified
merge: a standalone bounded, read-only immutable-commit source observer, distinct from
working-file reader and self-candidate execution transport. Explicit canonical repository
root, full selected commit ID and1–4 selected lib/test Dart paths; verify actual commit/tree
objects, bound complete tree metadata, refuse unsafe/symlink/Git-link/ambiguous entries,
and return exact selected blob bytes/hash/count plus commit/tree/manifest identities.
Preserve BOM/CRLF/multibyte bytes and distinguish selected working observations from
committed content. Do not execute filters/hooks/submodules, fetch/network, project code,
modify index/refs/files or allocate a candidate. Use fixed argument-vector Git object reads
with scrubbed configuration/environment, deadlines/output bounds and owned cleanup;
initial repository-layout subset must be explicit and fail closed. Cover dirty/untracked/
conflict invariance, missing/wrong objects/paths, limits/configuration hazards/Stop and
actual owned Mac fixtures. App UI/consent/current-plan binding, full repository copy,
branching, runnable adapter checks and model sharing remain later separate admissions.
This standalone observer does not claim an imported app action or certify working state.

Investigation final publication, exact fresh review, all requiredCI and verified merge
remain pending. Existing #404 covers the next prerequisite; no new issue or backlog.


### F20 / #404 — verified snapshot admission and commit observer implementation started, 20 November 2026 UTC

PR813 verified merged10ce9d787c21e9cbe5d2b8cbedf0b8cf13bc50b9; inspected tree
1649b2796270f41f2ce45d1be9d7551d5df57689. Fresh exact review remote4faf845319e1b8599b0fb24b285f6e4b43f575f7
againsta49895b562f5e570f3e2d1dc2596e022902f3310 matched local/remote diff and three
append-only canonical docs; no blocking findings or review threads. RequiredCI44805051393
Python136526741630/Flutter136526742168 allrequired/poststepsSUCCESS; completed logs
inspected. Pluginmain/mergedPR/404OPEN and fetchedmain/tree verified. Coordinator recorded
checks/review/merge/outcome and released completed claim/integration. Four owned Git
probes,44snapshot/33Gitmetadata/31source Python regressions and prior18Flutter checks
establish the prerequisite findings, not a newly delivered imported copy/edit app flow.
Attempted PR attachment hit existing100item limit; no unrelated attachment removed.

Coordinator investigation segment: start-to-merge978.2seconds, paired CI observation
wait464.2seconds, zero recorded review rework and one outcome-verification attestation.
These cooperative/manual intervals and investigation tally are not provider CI timing or
a new app user capability; escaped defects remain unknown despite zero observations.
Owner dirty checkout/processes preserved; no model/source-write/install/deployment effect.

Immediately claimed404-imported-commit-observer from verifiedmain in same registered
worktree, solewriter; no independent eligible disjoint second task. Existing404 covers the
next concrete F20 prerequisite. Coherent outcome: standalone bounded read-only observer
of explicitly selected Dart blobs from an actual immutable Git commit, distinct from
working-file capture and self-candidate execution transport. Claim owns new helper/tests,
requiredPython CI fixture wiring and these three canonical docs; no app asset/controller/
UI integration. Acceptance: canonical root/full nonzero40hex commit and1–4 literal paths;
actual object-type/ID/byte agreement, bounded complete tree metadata and exact selected
UTF8/BOM/CRLF bytes/hash/count with commit/tree/manifest identities. Fail closed on
unsafe modes/path/case collisions/Git-links, missing objects/paths, bounds and unsupported
repository layouts. Fixed bounded argument-vector object reads, scrubbed config/env, no
network/lazyfetch/filters/hooks/submodules/project execution or root/index/ref/candidate
writes. Owned Stop/deadline/output/cleanup, actual disposable Mac fixtures and required
CI/freshreview/verifiedmerge precede completion. App consent/current-input/plan binding,
copy/branching/runnable adapters and external model sharing remain separate prerequisites.

Started pure validation only in tools/imported_commit_source.py: frozen request/readset,
strict SHA1 object-byte verification and limits, commit-to-tree binding, immutable binary
tree entries with Git ordering/mode/name/duplicate/case-collision/count guards, and exact
selected blob byte/hash/base64 records. No filesystem/process reader or CLI is exposed in
this start. A commit ID alone is insufficient: future reader must verify each returned
commit/tree/selected-blob object's bytes and bound traversal before publication; unselected
working content, clean/conflict state, authenticated origin and write permission remain
unknown. These supplied-data parsers do not establish app source provenance on their own.

Nine new tests passed, including malformed/mismatched/truncated objects, unsafe symlink/
Git-link tree modes, case collisions, ordering/count/byte/readset bounds, immutable data,
empty and BOM/café/CRLF bytes, and actual owned Git commit/tree/blob parser agreement.
Adjacent33Gitmetadata and31selected-source regressions passed. Logs/tmp/asg404-commit-
observer-{parser,git,source}-start.log. Newly owned Git fixture removed; original fixture
bytes preserved. No source files/records in the owner's repository were read or changed
by fixtures; no model/build/execution authority inferred. Native object-reader process/
layout/configuration hazards, aggregate/traversal limits, response protocol, Stop/cleanup,
CLI and CI wiring remain pending within the active coherent implementation claim.
FullF20/CE01 and unavailable-platform400 remain open; marketplacegate/F23-last unchanged.


### F20 / #404 — bounded immutable commit source observer, 20 November 2026 UTC

Implemented standalone tools/imported_commit_source.py and its regression fixtures.
Explicit canonical POSIX root, nonzero full40hex SHA1 commit and1–4 literal selected
lib/test Dart paths; no ref/revision expressions. Actual commit bytes bind the root tree;
every traversed binary tree and selected blob is checked against its kind/size/Git object
ID. Tree modes/order/component/case-collision/duplicate guards reject symlink/Git-link
entries even outside selected paths. Limits: commit64KiB, tree metadata1MiB total,2048
files/128directories/16levels, selected32KiB each/64KiB total, response128KiB and10second
read deadline plus bounded owned cleanup. Exact UTF8/BOM/CRLF/multibyte/empty bytes and
SHA256/base64 are retained. Response binds root/commit/readset/tree/full flat metadata
manifest SHA256/count; source_verified=false, working_tree/conflict unknown.

Initial layout deliberately limited: direct no-follow .git directory and primary object
store; standard bounded local config whitelist (core storage flags plus passive user/
remote/branch values). Includes/extensions/worktree overrides/fsmonitor/filters and
nonstandard syntax refuse. Linked/bare/shallow layouts, alternates, hardlinks, symlink
metadata and unsupported object-info/pack entries refuse. Ordinary loose and packed
objects are tested. This is an explicit subset, not arbitrary-repository compatibility.
No-follow held directory identities, stable config/HEAD/pack/info signatures and pre/post
command validation reject detected repository changes. These cooperative checks are not
an OS sandbox against hostile same-user mutation or atomic full-working-tree capture.

Only fixed /usr/bin/git cat-file size/type-specific object reads are dispatched with
argument vectors, scrubbed environment, disabled global/system config, no replacement
objects/grafts/lazyfetch/network/prompt/optional locks, and explicit hooks/fsmonitor
disabling. No shell, diff filters, hooks, submodule operations or project commands. Every
owned child is killed/reaped on Stop/deadline/output overflow; uncertain cleanup returns
refusal and stops further reads. CLI supports -I/-S/-B and emits only bounded typed JSON
with exit0 observed /2 refused; partial source files/identities never publish on refusal.
A caller must still own the outer helper deadline, cleanup and cross-job exclusion.

Manifest metadata contains path/mode/Git blob ID, not unselected blob content or sizes;
it does not establish total repository byte bounds, clean state or copy readiness. App
consent/native-host ownership/current-input/plan binding, source copy/branches/checks and
model sharing remain unimplemented separate admissions. No app asset or user action is
added by this standalone prerequisite; no inference/runtime/platform acceptance claim.

27 observer tests passed on this Mac, including actual isolated CLI, dirty/untracked and
three-stage index invariance, exact BOM/empty bytes, packed objects, corrupt loose object,
unsafe tree modes/case collisions, layout/configuration/metadata indirection, size/tree/
depth/response bounds, Stop/deadline/output child kill/reap, uncertain cleanup with no
further dispatch and changed-config result refusal. ResourceWarnings-as-errors passed.
Existing snapshot44/Gitmetadata33/selectedsource31/inventory9/product32/coordinator20
checks passed separately. Logs/tmp/asg404-commit-observer-{native-tests,existing-candidate,
existing-git,existing-source,inventory,product,coordinator}.log. The corruption fixture
initially could not edit its own Git-read-only object; fixture chmod/restore corrected
that test setup and all reranPASS. No owner-source/index/refs/records or last outputs changed.

The required Python job now runs the27observer fixtures. Only that test step was added;
job names, permissions, pinned actions and protection are unchanged. No Flutter runtime,
assets/dependencies or platform runner changed; required finalCI still reruns Flutter
checks/web and all Python fixtures. Publication, exact fresh review, completed requiredCI
and verified merge remain pending. FullF20/CE01/unavailable-platform400 remain open,
marketplacegate/F23-last preserved, solewriter/no independent eligible disjoint task.

Next coherent app outcome after verified standalone merge: explicitly compare every
captured file of a saved comparison with a user-selected full commit, preserving working
history. Add strict typed request/response/comparison, packaged native host with owned
Stop/cleanup, frozen five-app-input read fences and shared-store reader exclusion, and
a focused consent/result screen entered from history. Consent names root/commit/all paths/
Python plus complete bounded tree-metadata access; no automatic read/ref resolution or
approval revival. Keep previous results stale on refusal/change/Stop/disposal; no source
write/copy/model/project commands. Actual disposable Mac/nativeDB and injected IAB tests
plus required app checks/builds/CI/freshreview/verifiedmerge precede that app capability.


Fresh PR814 review found two Stop ordering defects before merge: an already-stopped
request opened repository metadata before checking Stop, and Stop becoming true during
repository validation did not prevent the following Git child dispatch. Both new
regressions fail the initial reviewed source (/tmp/asg404-commit-observer-review-stop-
before.log). Fixed by checking Stop/deadline before repository.open and again immediately
after validation before Popen. No initial-head approval/CI may authorize the revised head.

Revised source passes29observer tests with ResourceWarnings-as-errors, including both
new Stop regressions and all actual native CLI/object/bounds/lifecycle cases. Adjacent
snapshot44/Git33/working-source31/inventory9/product32 reranPASS; logs/tmp/asg404-commit-
observer-review-{stop-after,candidate,git,source,inventory,product}.log. No Flutter runtime/
asset/dependency changed. Forward publication, fresh exact revised review and all required
CI on the final head remain mandatory. Initial fixture checks and source receipt retain
their original hashes; revised evidence is separate, not a replacement of earlier events.


### F20 / #404 — verified commit observer and app comparison started, 20 November 2026 UTC

PR814 verified merged9929c4a84cb33dc94a316fae0e655ccb466e81e5; exact final tested tree
ca9274caa0c9ede4f7b1ce7618a482b7ed199434. Fresh revised review remote d5530f2592463fd1d2861294d2ce3464a89f90fd
against10ce9d787c21e9cbe5d2b8cbedf0b8cf13bc50b9 matched local/remote diff and tested
contents. Both Stop admission/dispatch findings were reproduced failing before, fixed
and retested;29observer cases and adjacent regressions passed. Initial CI44809988044
was cancelled and not reused. FinalCI44810576594 Python136545900475/Flutter136545900059
all required/poststeps SUCCESS, including new observer fixtures; completed logs inspected.
Final head/base/main unchanged and threads empty before protected expected-head merge.
Pluginmain/mergedPR/404OPEN and fetchedmain/tree verified. Coordinator recorded final
checks/review/merge/outcome and released integration/claim. Standalone data reader is
delivered; no app commit action/source copy/execute/model capability is claimed. Owner
dirty checkout/processes preserved. Attempted PR attachment hit existing100item limit;
unrelated attachments retained.

Coordinator observer segment: start-to-merge2216.3seconds, paired CI observation intervals
619.4seconds total (cancelled initial and successful final observed separately), one
recorded review-rework event and one standalone outcome attestation. These cooperative
manual intervals are not provider CI timing or a new app user workflow; actual escaped
defects remain unknown despite zero recorded escaped-defect observations.

Immediately claimed404-imported-commit-comparison from verifiedmain in same registered
worktree, solewriter; no independent eligible disjoint second task. Existing404 covers
the coherent app outcome: saved history opens explicit full40hex commit selection/read
consent, compares every original captured file with selected immutable commit content,
and retains historical records and stale last working results. Typed data/native host/
read-only store/controller/focused view/history wiring/tests/helper asset/inventory and
canonical docs are one claimed feature, not separate parser-only delivery. Freeze five
app records with existing durable zero-update fences and reuse baseline shared-store
reader lease across both workflows. Consent names root/commit/all paths/Python and
complete bounded tree-metadata access; no automatic read/ref resolution or revival of
plan approval. Owned Stop/late startup/disposal/uncertain cleanup, typed exit/status and
root/commit/readset identity agreement remain mandatory. No source copy/write/model or
project commands. Actual disposable Mac/nativeDB/IAB and fullapp/build/CI/freshreview/
verifiedmerge gates precede completing this app outcome.

Started pure immutable ImportedCommitReadRequest and ImportedCommitSourceObservation.
Requests freeze canonical POSIX root/Python outside project, exact full commit and ordered
paths. Strict128KiB response schema rejects duplicates/unknown fields, invalid authority
claims, malformed identities/types/counts, unsafe modes and path/readset/blob discrepancies.
Selected blob Git SHA1 is independently recomputed over exact bytes, while existing pure
working-source decoder validates SHA256/byte/base64/UTF8/BOM/bounds. Unattributed refusal
contains no invented root/commit/tree/manifest/files; typed decode alone proves no native
read or authenticated origin. Lists/bytes immutable; source_verified=false and working
state/conflict unknown. Commit/tree/manifest identities are supplied typed metadata until
an owned physical native read binds the exact request. Host/controller/store/UI/asset
integration and pure historical comparison model remain pending in this active claim.

Six new model tests plus8existing source-observation tests and architecture check passed
15total; analyzer clean, focused format clean and inventory9 PASS. Logs/tmp/asg404-commit-
comparison-{model,analyze,inventory}-start.log. Tests cover exact BOM/café/CRLF, frozen
selection, full-commit syntax, private malformed/duplicate/oversized schema, false working
state/source-verified claims, mismatched blob/mode/path/length and typed empty refusals.
Initial inventory correctly detected the newly added model; deterministic regeneration
updated current comparison inputs, then all9 checks passed. This is not fresh native/app
commit-comparison evidence. No native helper/model/source operation was dispatched by
this model-only start. FullF20/CE01 and unavailable-platform400 remain open; marketplace
gate/F23-last unchanged.

2026-11-20 — F20/CE01 #404 immutable-commit comparison app validation (pending PR merge).

Completed the coherent saved-history entry: explicit full40hex commit input and read
consent, typed exact-root/commit/readset observation, all-original-file historical byte
comparison, native host, five-record read-only durable fences, shared baseline/commit
reader lease, focused MVC screen and helper asset. Results bind commit/tree/manifest,
request/observation identities and every before/committed hash/count; they remain temporary
and unverified. No current approval is revived and no source copy/write, model request or
project command is authorized. Current working files/conflicts remain unknown.

The Mac host starts only the packaged observer in a private directory and owned session.
A complete PID marker is published atomically before Git can start; graceful Stop allows
helper child reaping, then bounded owned-group termination confirms no remaining children.
Late startup, streams, refusal attribution, disposal and uncertain cleanup fail closed;
uncertainty retains the shared reader lease. No foreign directory is recursively removed.
This is cooperative same-user process ownership, not an OS sandbox. Other platforms have
an explicit unavailable host, not verified native support.

Final checks: 69 focused Flutter tests; full2679 PASS with13 existing opt-in skips;
650 Dart files format-clean, analyzer clean, architecture included, acceptance inventory9
PASS and product claims32 PASS. Production web build and isolated unsigned macOS build
PASS. Bundle ID com.arsinha.asg.commitcomparisonvalidation; packaged helper hash matched
source. No installation, stable replacement, native GUI or live model verification claimed.
Logs /tmp/asg404-commit-comparison-{focused,full,analyze,format,inventory,web,native}-final.log;
source hashes /tmp/asg404-commit-comparison-final-input-hashes.json and build receipt
/tmp/asg404-commit-comparison-build-receipt.json bind final production inputs. Distinct
initial/final native event receipts are preserved; final event path is recorded in build
receipt and /tmp/asg404-commit-comparison-native-event-path.txt.

Actual disposable Mac Git/native DB fixture: exact BOM/multibyte/CRLF capture matched its
commit; a second commit changed the peer and retained target match; unavailable commit
preserved prior comparison as stale. Physical five app records, saved history, Git index,
HEAD and current working bytes stayed unchanged. Actual cooperative and SIGTERM-resistant
child fixtures confirmed group cleanup; early pending-marker Stop cleaned before observer
admission. Browser IAB injected-host fixture used current real controller/store/view and
synthetic records only: invalid HEAD never read, cancellation read0; matched/read1,
changedpeer/read2, wrongcommit/read3 rejection, selected_path_missing/read4 refusal,
delayed/read5 Stop, durable input change/read6 rejection, matched/read7 recovery and
cleanup uncertainty/read8 disabled further reads/input. Previous results remained stale
on failure; comparison writes0 and saved history unchanged throughout. One explicit
fixture-only input edit occurred; no owner source/model accessed. Owned port8402 server
stopped after verification. Browser evidence does not claim native execution in web.

Fresh exact PR review, required remote CI and verified merge still gate completion of
this app increment. Full F20/CE01 #404 remains open for immutable-context planning, explicit
isolated copy/admission, reviewable changes and safe execution. Unavailable platforms stay
under #400; marketplace gate and F23-last ordering remain unchanged.

### F20 / #404 — verified commit comparison and planning-context investigation started, 20 November 2026 UTC

PR815 protected merge8e091f1074f000cb9513338ae40a1abead02058e verified through pluginmain,
mergedPR/404OPEN and fetched tree88f015fbb4f93d33d5608ba24bcd1ddd699d4920, equal tested
contents. Fresh review exact remote50480a7f51bb809888e99b02f840155ea92dcacd against
9929c4a84cb33dc94a316fae0e655ccb466e81e5 matched normalized local/remote diff; no blocking
findings or unresolved threads. RequiredCI44820630617 Flutter136580311864 and
Python136580312306 every required step/poststep SUCCESS; completed logs inspected.
Local69focused/2679full13existingopt-in skips, format/analyze/inventory9/product32,
productionweb/isolatedMac and actual disposable nativeDB/Git/IAB guards establish the
bounded read-only comparison outcome. No current approval, whole-copy readiness, source
write/copy/execution, nativeGUI/install or model capability claimed. Completed ownership
and integration released. Attachment attempt hit existing100identity limit; unrelated
attachments retained. Owner checkout's6unrelated dirty files and processes preserved.

Coordinator manual start-to-merge4065.4seconds, paired observed CI interval535.2seconds,
zero recorded review rework and one verified bounded app outcome. These are cooperative
manual intervals, not provider CI timing; escaped defects remain unknown despite zero
recorded escaped-defect observations.

Immediately claimed404-commit-context-admission on verifiedmain in same registered
worktree; existing umbrella404 covers this bounded prerequisite, no new issue/backlog.
Solewriter, no independent eligible disjoint second task. Owned scope is these three
canonical documents only; disposable probes stay outside repository. Acceptance: map
immutable commit data into advisory/manual-plan identity without discarding commit/tree/
manifest/full readset, current app metadata/requirements or source-sharing consent;
identify store/controller/recovery changes needed before a coherent app implementation.
No app source/model/copy/write/execution effect in this investigation. Fresh reviewed
publication/requiredCI/verifiedmerge still gate completing the investigation.

Inspected ImportedRepositoryContext, ImportedSourceContext, ImportedAdvisoryRequest/
Record/Store/Controller and ImportedPlanStore/Controller. Generic advisory accepts an
ImportedRepositoryContext but expects metadata.root in its record; current manual-plan
store admits only typed document or working-source capture and reconstructs those types
during durable save. It cannot safely accept an immutable comparison as current context.
Historical proposal models/stores remain tied to ImportedSourceContext; that scope must
stay explicit rather than silently treating matching commit bytes as working-source proof.

Three disposable Dart probes plus51relevant existing context/advisory/plan/proposal tests
passed54total. Log /tmp/asg404-commit-context-admission-rechecked.log; probe source
/tmp/asg404_commit_context_admission_probe_test.dart. Equal selected bytes from two full
commit IDs retain different new comparison identities, but hypothetical flattening into
existing working-source context collapses both context and advisory request identities
and equals the approved historical plan context. This is a demonstrated unsafe conversion
to avoid, not an exposed app pathway or newly discovered existing authorization bypass.
Strict captured-source restore rejects extra commit/tree/manifest fields, preventing an
in-place version1 extension. A valid30000byte capture is admitted by source bounds but
rejected by existing24KiB advisory prompt bound; no truncation or model request occurred.
An initial command named nonexistent imported_plan_store_test.dart and failed loading;
corrected to actual imported_plan_test.dart and all54reranPASS. Initial log retained.

Next investigation work: settle typed immutable-context canonical schema/restore and
identity matrix, current metadata/requirements fencing, optional advisory consent/view
provenance and manual-plan draft-before-approval semantics, plus recoverable history
compatibility. A coherent implementation must include its store/controller/UI path and
relevant adverse coverage; parser-only acceptance is insufficient. No automatic model
sharing or inference is needed for these deterministic admission probes. FullF20/CE01,
unavailable-platform400, marketplace gate and F23-last ordering remain unchanged.

### F20 / #404 — immutable-context admission findings, 20 November 2026 UTC

Completed local prerequisite investigation; publication/fresh review/requiredCI/verified
merge remain pending. Eight disposable admission/schema probes plus77relevant existing
context/advisory/manual-plan/proposal tests passed85total. Final log
/tmp/asg404-commit-context-admission-final-rechecked.log; prototype source
/tmp/asg404_commit_context_schema_probe_test.dart. Initial prototype used two arguments
instead of the existing three-argument RequirementsStore.save API; corrected and all85
reranPASS. Earlier failed log retained. Prototype records are supplied deterministic data,
not production schema/native admission or a new app capability. No live model request,
owner repository source operation, install/build/deployment or app storage mutation.
Existing regression fixtures use only disposable native databases and fake providers.

Verified findings:
- Equal selected bytes across different commits collapse identity if converted into the
  old working-source context; they can equal the historical approved plan context.
  Current app exposes no such conversion. Preserve its strict version1 schema.
- Commit comparison record identity includes observation time. Repeating the same request
  and content at a later time changes that record digest while request/observation digests
  stay equal. Do not use whole comparison digest or timestamp as stable planning identity.
- A proposed separate canonical captured-imported-commit-context scope can retain metadata,
  requirements, fullcommit/tree/manifest/count/readset and per-file mode/blob/SHA256/count/
  text. Projection probes change identity for each provenance component. Mutated prototype
  projections are not claimed valid; strict production decoding remains implementation.
- Existing generic advisory request/answer plumbing can carry this prototype identity:
  prompt contains exact commit/tree; completed answer retains root and context digest,
  excluding captured source plaintext. Existing advisory store's frozen input authorization
  rejects changed requirements; changed SDK metadata does not match captured inputs.
  Generic plumbing is not a user entry or sharing grant. Current24KiB prompt bound can
  reject a valid30000byte source capture; preserve refusal rather than truncate data.
- Existing default planning workspace loads an unknown immutable-context plan only as
  historical/inactive. It cannot approve that record against ordinary metadata context;
  attempted approval retains original bytes. A new explicit typed store/view path is
  necessary. No existing proposal/history schema should silently accept this new type.

Selected implementation boundary after verified merge: one coherent committed-source
review and user-authored manual-plan workflow, entered explicitly from a successful,
nonstale, cleanup-settled commit comparison. It includes typed context/restore, current
app-input fence, review/plan entry, manual-plan store/controller/view provenance and all
relevant recovery/adverse tests. No model integration or source proposal/copy/execution
is required for that bounded user outcome. Existing404 covers it; no new issue needed.

Required design constraints for that implementation:
1. Canonical separate versioned context; immutable lists/bytes, duplicate/unknown/type/
   Unicode/byte/count/path/mode/blob/hash guards and exact canonical restore. Bind root,
   full commit/tree/manifest metadata, complete selected readset and exact committed
   UTF8/BOM/CRLF text, plus workspace inspection and requirements. Source_verified=false;
   working/conflict unknown. Workspace package/SDK/runners are captured app observations,
   not parsed from or verified for the selected commit. Exclude observation timestamp,
   Python path and comparison-record digest from stable context identity; keep read-event
   provenance separately in comparison UI. Canonical source data never becomes authority.
2. Context preparation is an explicit controller action after owned cleanup. Recheck the
   exact comparison request/current commit and frozen five app records with existing
   durable zero-update fences before returning context. Stale/refused/changed-input,
   disposed/pending/uncertain work cannot prepare context. Changed selected bytes are
   legitimate committed context, not a requirement to match the historical capture.
3. Extend plan storage with one mutually exclusive typed immutable capture alongside
   existing document/working-source captures. Preserve it through internal transactional
   snapshot reconstruction; validate metadata/requirements and exact current saved plan.
   Existing keys/plan record format stay unchanged. Existing current draft must be saved
   before explicit approval; new context invalidates prior approval. Failed/stale/disposed
   writes retain saved records. Reopening/repeating the exact capture yields stable identity;
   different commit/tree/manifest/requirements yields inactive historical approval.
4. Comparison and planning views show full immutable identity, selected source/hashes and
   context limits. Entry alone never reads files, shares text or saves/approves a plan.
   Saving stores source-containing context in ASG application records with clear local
   persistence wording. Default root plan remains historical until explicit compatible
   context is supplied; saved source-comparison history remains recoverable after a new
   manual plan. No source-proposal extension, repository copy/write or execution action.
5. Verify pure malformed/identity/byte/restore cases, preparation and save races/disposal,
   shared read ownership, historical plan/context reopening and actual disposable nativeDB,
   narrow/replacement/navigation widgets and IAB manual flow. Run format/analyze/fullFlutter,
   inventory, relevant web/isolatedMac builds, exact fresh review and allrequiredCI before
   completing the app outcome. Platform acceptance beyond this Mac remains under400.

Optional future advisory entry requires separate displayed immutable provenance and local
model-sharing consent, exact response identity and retained last-answer recovery. It is
not automatically enabled by the manual-plan workflow; no external endpoint sharing or
F23 acceptance is inferred. FullF20/CE01, isolated-copy/run prerequisites and #400 stay
open; marketplace gate and F23-last ordering remain unchanged. This investigation changes
only three canonical documents. No runtime/dependency/asset/workflow source changed, so
unrelated local builds were not repeated; required remote CI still gates the final PR.

### F20 / #404 — verified immutable-context investigation and manual planning implementation started, 20 November 2026 UTC

PR816 protected merge7fbd073fab0f79cfa7664bcc0d01c37817972502 verified by pluginmain,
mergedPR/404OPEN and fetched tree7d101220bef5196afb61c581c7584d01cb29654e, equal reviewed
contents. Exact fresh review remotece6f8d8cb2474996671a3a9e4f2f31bcd42c6855 versus
8e091f1074f000cb9513338ae40a1abead02058e matched normalized local/remote diff; only three
append-only canonical docs, no blocking findings or unresolved threads. RequiredCI
44823279140 Flutter136589337885/Python136589338552 every required step/poststep SUCCESS;
completed logs inspected. Eight disposable probes plus77existing regressions passed85;
prototype limitations explicitly retained. Completed claim/integration released. PR
attachment hit existing100identity limit; unrelated attachments retained. Owner six dirty
files and processes preserved. No new model/source-copy/execution/install/deployment effect.

Coordinator manual investigation start-to-merge1158.7seconds, observed CI interval641.6
seconds, zero recorded review rework and one prerequisite outcome-verification attestation.
These are cooperative manual observations, not provider CI timing or a new app user
workflow; actual escaped defects remain unknown despite zero recorded observations.

Immediately claimed404-committed-source-planning from verifiedmain in same registered
worktree, solewriter/no independent eligible disjoint second task. Existing404 covers one
coherent app outcome: successful nonstale settled commit comparison explicitly prepares
committed-source review and a user-authored manual plan, bound to full commit/tree/manifest/
selected bytes and current workspace metadata/requirements. Claim includes typedcontext,
comparison preparation/store/controller/view/workspace wiring, typed plan store/controller/
view, pure/store/race/widget/nativeDB/reopen/IAB tests, inventory and these canonical docs.
Store context remains mutually exclusive with old document/working-source contexts and
must survive transactional snapshot reconstruction. Preserve existing app keys/formats,
draft-before-approval, last working records and no automatic sharing/read/save/approval.
No source-proposal, copy/write/execution or new model entry is authorized. Full required
checks/builds/freshreview/CI/verifiedmerge still gate completing this coherent app workflow.

Started ImportedCommitContext pure model and seven regression tests. Separate canonical
captured-imported-commit-context scope binds workspace metadata/requirements, exact full
commit/tree/manifest/count/orderedreadset and every mode/blob/UTF8/BOM/CRLF/text/hash/count.
Stable context identity excludes Python path, observation timestamp and whole comparison
event digest. Captured workspace metadata is not committed toolchain verification.
Source_verified=false, working/conflict unknown. Strict duplicate/key/type/canonical/
Unicode/128KiB guards and reconstruction through existing strict observation decoder
independently check selected blobs/bytes/modes/hash/path limits. Restoring supplies history
only, with no fabricated interpreter/live-read identity or I/O. Lists/bytes remain immutable.

Seven new tests plus existing observation/comparison/source-context/architecture tests
passed31total. Exact BOM/café/emoji/CRLF and empty bytes roundtrip; different commit/tree/
manifest/mode/content/requirements change identity, Python-only changes do not; malformed
schema/authority/byte/hash/blob/path/count and unpaired Unicode refuse privately. Valid
64KiB selected data whose JSON text expansion exceeds128KiB refuses without truncation.
Focused format zero-change, analyzer clean from Flutterroot and inventory9 PASS after
new-input regeneration. Logs /tmp/asg404-committed-source-planning-{context-start,
analyze-rechecked,inventory-start}.log. These checks establish a pure model start only;
store/controller/UI integration, race/reopen/nativeDB/IAB/fullapp/build validation remain
pending in the owned claim. No helper/model/source operation was dispatched. FullF20/CE01,
unavailable-platform400, marketplace gate and F23-last ordering remain unchanged.

### F20 / #404 — committed-source manual planning app validation, 20 November 2026 UTC

Completed the owned coherent app implementation locally; publication/fresh exact PR review,
requiredCI and verifiedmerge still gate completion. Successful nonstale cleanup-settled
commit comparison now explicitly prepares a separate immutable planning context and opens
source review/user-authored plan. Preparation acquires the shared reader lease, freezes
and verifies the same five app records through durable zero-update fences, checks exact
request/observation identity and returns no context after Stop, changed inputs/commit,
replacement/disposal or uncertain work. It dispatches no helper and writes no records.
Changed committed bytes are valid historical planning data, not current working-file proof.

ImportedPlanStore/Controller retain mutually exclusive typed immutable/document/working-
source contexts through transactional snapshot reconstruction. Existing keys/record formats
stay unchanged. A current draft must be saved before approval; new commit/tree/manifest/
source/requirements changes make historical approval inactive. Failed/stale/disposed or
concurrent writes preserve the last record. View/workspace entry shows fullcommit/tree/
manifest, exact source/hashes and local source-containing app-record persistence wording.
Workspace metadata is not verified for the commit; working/conflict state remains unknown.
Existing saved source-comparison history is preserved. No source-proposal extension,
repository write/copy/execution, model-sharing/request or implicit plan save/approval.

Local boundary review added a regression for final idle-notification disposal. It failed
initial source: preparePlanning returned context after its final update disposed the owner.
Fixed by holding the candidate until cleanup/idle notification completes and rechecking
canPreparePlanning afterward. Regression FAILbefore/PASSafter logs
/tmp/asg404-committed-source-planning-idle-{before,after}.log. Initial full2702/build/event
receipts remain separate; revised final evidence below binds fixed inputs. Early test
setup failures (double disposal, lazy-list scrolling) and test-only braces/scroll hit-test
warnings were corrected; final focused run has no warning or failure.

Revised validation:77focused tests PASS; full2703 PASS with13existing opt-in skips;
653files zero-change format, analyzer clean, architecture included, inventory9/product32
PASS. Productionweb build and isolated unsigned macOS build PASS. Distinct validation
bundle ID com.arsinha.asg.committedplanningvalidation and packaged helper bytes verified;
no native GUI launch, installation, stable replacement or platform-device claim. Revised
logs /tmp/asg404-committed-source-planning-{focused,full,analyze,format,inventory,product,
web,native}-revised.log. All14 checked runtime/test/helper/dependency input hashes unchanged
in /tmp/asg404-committed-source-planning-input-hashes.json. Build receipt
/tmp/asg404-committed-source-planning-build-receipt.json binds source inputs, bundle/helper
and browser fixture; initial receipts preserved with -initial suffix. Distinct native event
path is in that receipt and /tmp/asg404-committed-source-planning-native-event-path.txt;
old source observations were never overwritten or relabelled as revised evidence.

Actual disposable Mac Git/helper/nativeDB phase: captured BOM/café/CRLF bytes, matched
firstcommit/changedpeer secondcommit/refused object; explicit new immutable manual draft
and approval, DBclose/reopen and typed canonical context restore. Compatible explicit
context reopens approved; ordinary workspace leaves approval inactive. Only plan record
changes in the planning phase; saved source comparison, source bytes, index and HEAD
unchanged. Owned temporary root removed. Positive native proof complements synthetic
pending-prepare Stop/disposal/commit/requirements/shared-lease races and failed/disposed/
changed-requirements/concurrent plan saves, plus replacement and narrow2x-text widgets.

IAB used real revised model/store/controller/views with synthetic host/records only.
Initial reads/writes0, plan entry disabled; consented commitA read1, explicit review no
additional read/write, source/commit/tree/manifest visible. Manual draft save and explicit
approval produced2app-record writes. Returning comparison was stale until recheck.
Samecommit read2 recovered approved plan. Synthetic failed-save read3 retained previous
saved text, kept edits and displayed inactive approval/error. Recovery read4 reopened the
original approved record. DifferentcommitD read5 with identical bytes opened different
context identity and inactive historical approval. Source expansion showed selected hashes/
counts/text. App writes remained2 and saved comparison unchanged throughout; fixture edits0,
model requests0. Browser check is injected UI, not a native Git read in web. Owned port8403
server stopped after final observation. Binding required localhost permission; successful
owned server used loopback only, with no external exposure or install.

No second independent dependency-ready disjoint task existed. FullF20/CE01 #404 remains
open for committed-source change proposals, isolated copy/admission and safe execution;
unavailable-platform acceptance stays under400, marketplacegate/F23-last unchanged.
Next eligible work after verified merge: inspect exact committed-context/approved-plan
proposal and history admission, preserving old working-source schemas and avoiding
conversion that discards commit identity. Use existing404, actual bounded local evidence
and one coherent next outcome; no speculative backlog or source execution permission.

### F20 / #404 — committed planning verified and proposal admission investigation started, 20 November 2026 UTC

PR817 protected mergec97c82b9a40c81fe859938c38852c6cd442772db verified through pluginmain,
mergedPR/404OPEN and fetched tree0ce7a4dd0850aed959482971e7030cf436ae1931, equal tested
contents. Fresh exact review remote9dd1ac58f2fcd1843bd1355adfa0ba296bdb768d versus
7fbd073fab0f79cfa7664bcc0d01c37817972502 matched normalized local/remote diff and14revised
checked inputs. RequiredCI44828387289 Python136606733011/Flutter136606733553 every
required step/poststep SUCCESS; completed logs inspected. No remaining blocking finding
or unresolved conversation.77focused/2703full13existingopt-in skips, format653/analyze/
inventory9/product32, web/isolatedMac and actual nativeDB/IAB outcomes verified. Initial
local review's idle-notification disposal defect was fixed before publication with failing
then passing regression and distinct revised receipts. Completed claim/integration released.
Issue404 updated with verified progress, preserving open fullF20 scope. Attachment attempt
hit existing100identity limit; unrelated attachments retained. Owner six dirty files and
owner-started processes preserved; no model/install/stableapp/deployment effect.

Coordinator manual start-to-merge2174.8seconds, observed CI interval615.4seconds, one
pre-publication local review-rework observation and one verified bounded manual-planning
app outcome. These are cooperative manual measurements, not provider CI timing. Actual
escaped defects remain unknown despite zero recorded escaped-defect observations.

Immediately claimed404-commit-proposal-admission on verifiedmain in same registered
worktree, solewriter; no independent eligible disjoint task. Existing404 covers the next
bounded prerequisite, no new issue/backlog. Claim owns these three canonical documents;
disposable probes stay outside repository. Acceptance: inspect immutable-context/current-
approved-plan proposal and history admission, exact diff/text identity and bounds, durable
record validation/quarantine/reopen and preservation of working-source records. Define one
coherent committed-source preview/save/reopen implementation boundary with adverse cases;
no source copy/write/execute/model effect. Publication/freshreview/requiredCI/verifiedmerge
remain gates before completing this investigation.

Started read-only inspection of ImportedSourceProposal/Record/Store, SourceLineDiff,
ImportedPlanStore and StudioDatabase validation/reopen policy. Existing proposal/record
models are deliberately typed to working-source context; old historical decoder restores
that strict version1 context before rebuilding the proposal. Immutable context must not
be flattened or passed through that history schema. Existing proposal preview has stricter
16KiB/500line bounds than32KiB source-read capture. New history prefix would require its
own strict record validator/storage identity and corruption-recovery admission before any
production save; StudioDatabase currently rejects unsupported record prefixes.

Four disposable probes plus20existing line-diff/proposal/record/store regressions passed
24total. Log /tmp/asg404-commit-proposal-admission-start.log; probe source
/tmp/asg404_commit_proposal_admission_probe_test.dart. Exact diff tokens reconstruct
committed BOM/café/CRLF, empty before text and replacement without final newline. Same
selected bytes do not make immutable context restore as working source; substituting new
context into old history refuses and leaves original bytes unchanged. A readable30000byte
committed source capture is valid but outside existing bounded proposal preview; no data
truncation or write inferred.

Actual owned temporary nativeDB probe stores an existing working-source comparison and
an immutable manual-plan record together. Production setString rejects a hypothetical
new committed-proposal prefix before writing, preserving both records. Direct adverse
fixture injection of that unsupported prefix makes reopen fail closed; removing only the
owned injected fixture row restores reopening with exact original plan/context/history.
This bypass exists only inside the disposable fixture, not in an exposed app path; it is
not an existing app authorization bypass. It demonstrates why a future prefix must be
validated and given deliberate quarantine/recovery treatment in the coherent change.
Owned DB/root removed; no owner-source/helper/model operation occurred.

Remaining investigation: settle versioned committed proposal/record provenance, approved-
plan and full context binding, literal target/replacement bounds, failure-retained drafts,
transactional expected-input/current-plan checks, separate history key/native quarantine,
and focused review/reopen navigation. A diff is review data, not an applicable patch or
copy/write/execution grant. FullF20/CE01, isolated-copy/run acceptance and400 remain open;
marketplacegate/F23-last ordering unchanged. Active claim retained for next continuation.

### F20 / #404 — committed-source proposal admission findings, 20 November 2026 UTC

Completed local investigation; final publication/freshreview/requiredCI/verifiedmerge remain
pending. Five disposable probes plus34existing line-diff/proposal/model/history/controller/
nativeDB regressions passed39total. Final log /tmp/asg404-commit-proposal-admission-final.log;
probe /tmp/asg404_commit_proposal_admission_probe_test.dart. Earlier24test start remains
separate. Additional actual nativeDB probe confirms immutable-context plan saving rejects
a changed durable plan row despite an unchanged app cache; the winning draft and working-
source history survive, and close/reopen restores that draft without approval. No owner
source/helper/model operation, runtime code change, install or deployment occurred.

Admission conclusion: implement one committed-source preview/save/reopen workflow with
separate typed proposal/record/controller/store/view and a validated additive history key.
Reuse SourceLineDiff and the established preview text policy; do not convert commit context
or relax existing working-source models, keys or decoders. The current importedCommitContext
retains all immutable provenance; a proposal binds that complete canonical context and the
exact full approved ImportedPlan JSON, not merely plan text or a historical approved flag.
Approval stored in reopened comparison history is historical evidence, never current consent.

Selected bounded implementation after verified merge, under existing404:
- Pure ImportedCommitProposal: explicit immutable context + exact current approved plan,
  one literal selected Dart path and changed user-authored replacement. Preserve current
  16KiB/500line before/after limits, Unicode/BOM/CRLF identity, bounded deterministic diff
  and coarse fallback.32KiB-readable files may be ineligible for preview; retain the read
  context and explain refusal without truncation. Empty selected files remain valid before
  content. Root comes from captured metadata; context digest binds commit/tree/manifest/
  ordered readset/mode/blob/hash/count/text and app metadata/requirements. Proposal identity
  includes full reviewed-plan digest, selected target/before/after hashes and replacement;
  source_verified=false. A diff is review data, not an applicable patch or operation contract.
- Pure ImportedCommitProposalRecord: separate versioned historical scope carrying full plan
  (including strict canonical immutable context), canonical proposal and UTC recorded time.
  Recompute context/plan/proposal/file hashes during restore; reject duplicate/unknown/type/
  Unicode/noncanonical/oversized data and mismatched target/root/plan. Keep bounded256KiB
  history admission; JSON expansion can still refuse otherwise valid capture/preview and
  must preserve draft/history. Whole recorded-event digest may include recorded time;
  transient proposal identity is independent of the later history-save timestamp.
- Separate additive studio.importedCommitProposal.v1.<workspaceId(root)> key, one latest
  comparison per root as the existing working-source history does. Do not replace/migrate
  studio.importedSourceProposal.v1 or change ImportedPlan record format. StudioDatabase
  validates the new decoder and exact root/key identity before every production write.
  Add its prefix to deliberate unreadable-record quarantine on reopen so corrupt committed
  history is retained verbatim and surfaced locally without blocking working history or
  unrelated records. Never silently delete, reset or overwrite quarantined history.
- New store freezes four exact app records: folder references, requirements for root,
  current imported plan and the new history slot. Preview requires exact captured metadata/
  requirements and full current plan approved against that context. Mandatory conditional
  zero-update durable fences and transactional history compare-and-set recheck at pending
  consent/preview/save/publication boundaries. History-only access can reopen a prior record
  without fresh source capture or active plan approval, while visibly remaining historical.
  No runtime configuration or source read is needed; selected bytes are already captured.
- New controller owns loading/ready/busy/error/stale/current preview and last saved history,
  rejects duplicate or stale saves and binds explicit save consent to the exact preview
  object. Invalid or failed edits retain text, last preview and saved comparison; changed
  inputs mark preview stale. Disposal/replacement/late callbacks and final notifications
  cannot publish new results. A committed write followed by lost confirmation is treated
  as unconfirmed until explicit history reload, not automatically replayed or erased.
- Focused view owns target/text editing lifecycle and read-only diff rendering. Current
  typed immutable-plan screen offers preview only for compatible approved saved plan;
  the proposal controller must independently verify that state. Workspace adds a separate
  committed-history entry. Match existing explicit local-save review: disclose root/full
  commit/tree/context/plan/target hashes and that full captured source/plan/replacement is
  stored in ASG application records. Entry/preview are not saves or source/model operations.
  Reopened history shows immutable provenance and saved diff, with no implicit approval,
  file freshness, copy/write/build/execution or external-sharing claim.

Required representative failures and validation: unapproved/changed plan; same selected
bytes at different commit/tree/manifest; root/readset/target/hash/schema corruption; unsafe
or no-op/oversized replacement; changed requirements/plan/history during consent/preview/
write; stale nativeDB caches; save conflict/failure; disposal and controller replacement;
corrupt new record quarantine preserving old history and unrelated data; actual disposable
nativeDB save-close-reopen; no extra reader/model calls; narrow2x-text/keyboard/scrolling
and IAB injected flow. Run format/analyze/fullFlutter/inventory and relevant web/isolatedMac
builds, fresh exact PR review, allrequiredCI and verifiedmerge before completing the coherent
app outcome. New storage admission and history recovery belong in the same change as the
models/controller/UI, not a separately advertised parser-only feature.

Evidence limits: probes validate existing primitives and actual failure boundaries, not
an implemented new proposal schema or authenticated repository origin. Direct unsupported-
record insertion was only an owned adverse fixture; production APIs rejected it before
writing. Existing39passing tests are reference/admission evidence, not new app capability.
Only three canonical documents changed; unrelated local builds were not repeated. No
independent eligible disjoint task exists; dependent implementation waits for verified
merge. FullF20/CE01 and isolated-copy/run acceptance remain open; unavailable platforms400,
marketplacegate and F23-last ordering unchanged.
