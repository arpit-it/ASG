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
