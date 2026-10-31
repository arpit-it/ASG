# Product acceptance evidence (F17)

The version 1 [scenario manifest](product_acceptance_manifest.json) inventories
initial macOS/web checks and references existing tests. References identify a
suite to extend/run; their presence does not establish that the scenario passed.
The fixture, build, application launch, live inference, generated output and
manual interaction kinds remain separate. Native Android, iOS, Windows and Linux
cells are unavailable in this initial manifest, including on a host where a
fixture or build succeeds. This is an evidence collection foundation, not the
completed F17 baseline or a product support certification. No scenario is executed
by this tool. Real isolated-profile workflows remain pending.

`tools/product_acceptance.py` reads three JSON files and atomically writes a saved
evidence matrix. It uses only Python's standard library:

```sh
python3 -B tools/product_acceptance.py \
  --manifest docs/development/product_acceptance_manifest.json \
  --identity /tmp/current-acceptance-identity.json \
  --evidence /tmp/saved-acceptance-evidence.json \
  --output /tmp/acceptance-report.json
python3 -B tools/test_product_acceptance.py
```

The identity object has exactly these fields:

| Field | Required representation |
| --- | --- |
| sourceRevision | 40 lowercase hexadecimal characters, exact tested Git commit |
| requirementSha256 | SHA-256 of exact requirement snapshot used by F10 |
| inputSha256 | SHA-256 of exact approved source/input snapshot used by F10 |
| configurationSha256 | SHA-256 of effective scenario configuration |
| modelSha256 | SHA-256 of the exact model/revision/format identity |
| deviceSha256 | SHA-256 of sanitized host/device identity |
| sdkVersion, runtimeVersion, browserVersion | Numeric dotted version (up to four components) or `unavailable` |
| backend | `mlx`, `torch-mps`, `none` or `unavailable` |
| host | `macos`, `web`, `android`, `ios`, `windows` or `linux` |

Hash absent components using a stable explicit sentinel, e.g. the UTF-8 bytes
`unavailable`; do not invent a working model/device. Callers must collect exact
identities and rerun affected scenarios when they change. The collector compares
identities; it cannot discover changes or authenticate caller-supplied results.
Requirement/input hashes must come from the same F10 snapshots, not a prose
summary. Never hash credentials/prompts as identities or include them in records.

Evidence has `schemaVersion: 1` and `records: []` initially. Each record contains
exactly `scenarioId`, `checkId` (from the manifest), `target`, `status`,
`observedAt` (UTC `YYYY-MM-DDTHH:MM:SSZ`), `identity`, `manifestSha256`, and
`artifactSha256` (up to 16 SHA-256 digests of sanitized artifacts). Compute the
manifest hash using the module's `sha(manifest)` canonical JSON function. Only
`passed`, `failed`, `skipped`, and `unavailable` are accepted saved statuses.
Record one observation per scenario/check/target; replace it deliberately after
a rerun rather than relying on ordering. Keep historical runs separately.

The report marks absent configured evidence `missing`, unconfigured targets
`unavailable`, and any identity/manifest mismatch `stale`. Only an exact-current
saved `passed` record sets that cell's `currentPass`. This flag describes the
submitted observation, not semantic acceptance or current support. No aggregate
verified/support claim is produced. A saved failure also becomes stale after an
identity change; its original status remains visible in `savedEvidence`.

Inputs are bounded to 1 MiB each. Unknown/duplicate fields, unknown scenarios,
duplicate observations, future timestamps, invalid versions/digests and raw
artifact content are rejected before output changes. The schema accepts digest
artifacts only, no paths, prompts, logs, URLs, credentials or model weights.
Sanitize external artifacts before hashing/sharing; a digest does not sanitize
its underlying file. Errors deliberately omit input content and filesystem paths.
Existing report output survives validation failures. Do not overwrite evidence
inputs with report output. Reports are saved observations, never live health.


In the app, choose **Product acceptance evidence** in the home/workspace toolbar.
Paste the collector report JSON and choose **Inspect saved report**. The viewer
shows saved statuses by target, exact supplied identities, UTC observations and
artifact digests. Expand each check for details. Unknown fields, duplicate keys,
inconsistent statuses/identities, incomplete target groups and invalid timestamps
are refused with a sanitized error; an invalid replacement retains the previous
report. **Clear report** removes the session report and input. Nothing is saved
to project storage; reopen a report by pasting it again. Reports are limited to
1 MiB. This is a supplied-report reader, not an independent authenticity or live-freshness check. The viewer also compares
the report with the canonical manifest bundled in this app. Historical digest
mismatches are labeled explicitly; omitted configured scenario/check/target cells
and mismatched kind/requirement/target availability are listed separately. This
comparison neither rewrites saved statuses nor verifies source/model/device
freshness. A matching manifest or present cell is not a pass or support claim.
Loading failures show comparison unavailable with retry; original saved evidence
remains readable. The bundled specification can differ from a later repository
manifest until the app is rebuilt. Saved
passes do not establish current support or replace the pending real baseline.


## Separate repair observations (issue #263 extension)

The current manifest records three independent `bounded-repair` checks:
`real-repair-rerun` (`liveInference`), `repair-confined-checks`
(`generatedOutput`), and `repair-interaction` (`manual`). A saved inference pass
leaves the generated-output and interaction cells missing. A saved check pass
also leaves interaction missing. This extends the collector contract; it adds no
new observed repair run or product support claim.

For a fresh isolated repair workflow, obtain explicit repair consent, observe the
bounded failed-check diagnosis and actual model correction, and retain the exact
F10 requirement/input/source/approval/run linkage. Record `real-repair-rerun`
only for the observed model repair; record `repair-confined-checks` separately
only after the corrected candidate's resolve/analyze/test/build outcomes have
actually been checked. The provenance importer accepts either check with an
explicit target, status and UTC time; it never derives a pass from F10 digests.
Do not record downstream checks as passed when a prior check failed or stopped.

Then explicitly promote the verified candidate, open its served output and
exercise the repaired behavior, checking last-working preservation and restart
state as required by F17. Submit `repair-interaction` separately with sanitized
artifact digests only after observing it. The provenance importer rejects this
manual check because snapshot linkage alone cannot establish interaction.
Failures, skips and unavailable observations must retain their actual statuses.
These instructions do not authorize executing unrestricted generated code.

The added checks change the canonical manifest digest. Previously saved report
files remain historical snapshots; do not rewrite their hashes or relabel old
observations as new runs. Evaluating old records against the current manifest
marks them stale, while the new checks remain missing until separately observed.
Rerun affected workflows with exact identities before claiming current results.
Full F17 remains In progress, including the outstanding real macOS/web baseline.


## Native live observations, 28 October 2026

[Issue #257](https://github.com/arpit-it/ASG/issues/257) records two serial,
opt-in executions at source revision
`0f6f90c621b3e692c4e0bbbb55b5e0ccd90eb85d` in the
[sanitized observation record](acceptance/2026-10-28-native-live.json).
Both used the existing offline 4-bit Qwen3.5-9B MLX runtime on macOS/Metal.
The record includes UTC completion times, SDK/runtime versions, test file hashes
and an identity digest over the installed model files (canonical sorted JSON of
filename-to-SHA-256 mappings), including the actual weights digest.

From the Flutter root, run these serially against the explicitly started existing
runtime with an initialized cached Flutter SDK:

```sh
flutter test test/candidate_real_test.dart --dart-define=ASG_REAL_INFERENCE=true --reporter expanded
flutter test test/automatic_repair_real_test.dart --dart-define=ASG_REAL_INFERENCE=true --reporter expanded
```

The candidate execution passed in 47 seconds: real proposal, hash-tampering
refusal and last-working preservation, confined resolve/test/analyze/build with
four zero exits, explicit promotion, changed served JavaScript and database
reopen assertions. Its separate trusted-fixture test was skipped because
`ASG_REAL_GENERATION` was not enabled; that skip is not a live inference pass.
The repair execution passed in 55 seconds: a deterministic undefined-function
seed caused an actual analyzer failure, the correction used real model transport,
all four confined checks passed, and durable attempt/history, promotion,
last-working preservation and reopened-record assertions passed. The initial
broken proposal is a fixture; the corrective proposal is real inference.

Each test creates a disposable project/database root and deletes it after
cleanup. Production app storage and the installed stable application are not
used. These are native controller/service test executions, not native app launches.
Fetched JavaScript and HTTP success do not establish observable browser behavior;
no interactive browser review was enabled. No web-client workflow, manual
create/reopen, stop/timeout interaction, rollback/archive interaction or other
native device launch is established by these observations.

This JSON is a bounded historical observation artifact, **not** a collector input
or saved-report viewer document. The existing live tests do not export exact F10
requirement/input snapshots. Do not invent those hashes or convert the observations
into current-pass collector cells. Completing that provenance and the actual
isolated-profile macOS/web interaction baseline remains F17 work. F17 stays
In progress; rerun affected workflows after implementation/model/toolchain changes.

## Exact F10 provenance from opt-in live tests (issue #259)

The existing candidate and repair tests can emit a digest-only linkage after all
promotion and database-reopen assertions pass. Enable it explicitly for each run:

```sh
flutter test test/candidate_real_test.dart --dart-define=ASG_REAL_INFERENCE=true --dart-define=ASG_ACCEPTANCE_PROVENANCE=true --dart-define=ASG_TESTED_REVISION=<exact-40-character-tested-commit> --reporter expanded
flutter test test/automatic_repair_real_test.dart --dart-define=ASG_REAL_INFERENCE=true --dart-define=ASG_ACCEPTANCE_PROVENANCE=true --dart-define=ASG_TESTED_REVISION=<exact-40-character-tested-commit> --reporter expanded
```

Run serially against the explicitly started existing runtime. Verify the checkout
matches the supplied commit before running: the helper validates the revision's
format, not the truth of caller-supplied Git identity. Default runs emit nothing.
Capture the `ASG_F10_PROVENANCE=` JSON line separately from private test logs;
full logs may contain paths and generated content and must not be shared as the
sanitized artifact. An enabled run without complete current F10 evidence fails
rather than inventing missing identities.

The version-1 line includes only a fixed scope/scenario, tested source commit and
five digests: exact F10 requirements-board snapshot, saved input manifest,
generated source manifest, approval and saved run. The board hash uses F10's
existing model JSON encoding, and input/source/run hashes use
`RequirementRunIdentity`; do not reserialize them using the Python collector's
canonical JSON algorithm. Use `requirementSha256` and `inputSha256` directly when
assembling a collector identity. Keep the other three hashes as linkage in this
sanitized artifact. Add actual UTC/host/device/toolchain/model/configuration and
manifest identities from the same run before assembling collector records.
This linkage alone is neither a collector record nor a pass, live-freshness,
manual-interaction or support verdict. It contains no authored text, logs, paths,
source contents or prompts. The previous historical observations were not
retrofitted with invented hashes. Full F17 macOS/web interaction remains pending.

Actual serial executions at `a03439c4f66b7120710389954627e2dccaa48f4b`
passed: candidate49s (one separate fixture skip) and repair57s, each with four
confined zero-exit checks, promotion/preservation and reopened F10 linkage.
The [sanitized captured lines](acceptance/2026-10-28-f10-live-provenance.json)
include test-source digests and UTC completion times. They are historical
provenance artifacts, not current-pass collector cells or interactive UI evidence.


## Web create/reopen observation (issue #265)

The [historical web UI observation](acceptance/2026-10-28-web-reopen.json)
records an actual release web build and browser interaction at source
`8413e296101210d5dd532b550975e92eb91942cc`. It covers application launch,
app-led creation, requirement/task persistence, edited requirement persistence,
and an in-app prototype item/checked state across reload. The prototype is not
an independently generated app. No model was invoked. Browser numeric version
was unavailable and is recorded as such; this evidence cannot support an exact
browser-version compatibility claim. Screenshots are retained locally and their
digests identify those observations; their hashes alone do not authenticate them.

To repeat, use a clean checkout of the recorded source and the recorded Flutter
SDK; run `flutter build web`, then serve `build/web` with
`python3 -m http.server <unused-port> --bind 127.0.0.1 --directory build/web`.
Use a fresh loopback origin, confirm the initial app has no current project, and
retain the same origin throughout. A fresh origin isolates browser storage from
other app origins; it does not create a separate browser profile. Never point this
exercise at the user's existing app origin/profile. Stop the owned server afterward.

1. Choose New project. Describe a daily task planner, select Web app, review the
   summary and name it Acceptance 265. Create it through the wizard.
2. Open Requirements and tasks. Add R265 with title Reopen preserves acceptance
   edits and acceptance text The saved title and acceptance text remain visible
   after reload and explicit project reopen. Add queued T265, Verify durable
   browser state, linked to R265. Confirm revision 2 and 0/1 complete.
3. Reload. Enable Flutter accessibility again if needed. Confirm the project
   automatically reopens, then choose Projects and explicitly reopen it. Confirm
   R265, its exact acceptance text and T265 remain visible.
4. Edit R265 to Edited acceptance title survives reload and acceptance text
   Edited acceptance criteria remain exact after a second reload. Confirm revision 3.
5. Return to the prototype, add Durable item 265 and check it. Reload again; confirm
   the item and checked state remain. Reopen the board and confirm revision 3,
   edited title/acceptance and unchanged linked task.

This is historical human-readable observation evidence, not collector input or
a supplied current-pass report: exact F10 input/requirement identities were not
exported. Do not invent them from the public requirement document or these UI
strings. F17 remains In progress for the full isolated native/web scenario matrix,
including plan invalidation, real model/generated-output/repair interactions,
stop/timeout, rollback and archive workflows. Repeat affected observations after
source/toolchain/browser/configuration changes.


## Web archive restore/reopen observation (issue #267)

The [historical archive UI observation](acceptance/2026-10-28-web-archive.json)
records an actual release web build and app-led interaction at source
`51970cdd9088a403ea48344a3b8cef3bf989ffc7`. This extends the preceding create/reopen
observation with actual download, file selection, separate restore and reload.
The original and restored projects remain distinct. No application code changed.

Repeat with `flutter build web` in a clean checkout of that source, serve
`build/web` on a fresh loopback origin, and confirm the initial app is empty.
Use the same origin throughout; do not use the user's existing app origin.
A fresh origin isolates storage but does not create a separate browser profile.

1. Create Acceptance 267 through the daily task planner/Web app wizard.
2. Add a prototype item Archive item 267 and check it. Add R267 and acceptance
   `Restored requirement and prototype item survive reload.` Add queued T267,
   `Verify archive reopen`, linked to R267. Confirm board revision 2.
   The captured R267 title was `rchive preserves records`; preserve the actual
   saved text when comparing, rather than inferring the intended typed title.
3. Choose Portable records, Load saved records for export, review the summary
   and complete JSON, then Download archive file. Select that actual downloaded
   file through Select archive file. Enter new ID `restored267` and name
   `Restored 267`; choose Restore records into new project.
4. Confirm the saved-project success message. Return to Projects and confirm
   Acceptance 267 and Restored 267 both exist. Explicitly open Restored 267;
   wait until its heading is visible before reloading. Enable accessibility
   again if needed. Confirm Restored 267 reopens, Archive item 267 remains
   checked, and the board retains revision 2, R267 acceptance and linked T267.
   The restored prototype intentionally retains its original Acceptance 267 title.
5. In the restored project's Portable records, select a disposable JSON file
   containing `{invalid}`. Confirm the sanitized operation-failed message says
   existing records have not been replaced. Reopen the board and verify R267,
   T267 and revision 2 remain intact. No restore controls are offered for it.

The fresh web build/Wasm dry run, 85 focused archive controller/model/store tests
and 17 collector/import fixtures passed. Retained screenshot/build/archive hashes
identify local evidence only; hashes do not authenticate observations. The archive
contains disposable authored text and was not published. Browser numeric version
and exact F10 snapshots were unavailable, so this artifact is neither collector
input nor a current-pass/support claim. No native launch, live model, generated
source, executable history/rollback, stop/timeout or full F17 baseline is established.
F17 remains In progress. Re-run after relevant source/toolchain/configuration changes.


## Exact-identity candidate matrix (issue #269)

The [saved report](acceptance/2026-10-28-candidate-matrix/report.json) is the first
assembled native candidate observation with an actual measured environment and
exact F10 linkage. Its tested application source is
`7fb37b446e256002cc801d769e7d6c28f6cc7a5c`; the evidence publication is a later
documentation revision. It is a historical supplied-evidence report, not live
health, authenticated attestation or current product support. F17 stays In progress.

The [observation](acceptance/2026-10-28-candidate-matrix/observation.json) records
measured host, SDK, Python/package versions, per-file model digests and normalized
configuration. `modelSha256` hashes the sorted compact JSON mapping of model
filenames to measured file digests. Device/configuration hashes use the same
`product_acceptance.sha` encoding over their named objects. Runtime version is
Python's version; MLX and Transformers versions are separately recorded. The
configuration also binds measured Python/MLX/MLX-LM/Transformers versions, the
exact SDK revision/Dart object, generator Python version, and exact
test/provider/server/tool/lockfile bytes. No private
logs, paths, authored prompts or source contents are included.

The actual offline Qwen3.5-9B candidate test passed in 49 seconds: model proposal,
tamper refusal/preservation, confined resolve/test/analyze/build (all exit zero),
explicit promotion, changed served JavaScript and durable database reopen. One
separate trusted fixture was skipped. The runtime started for this run was verified
ready/idle and stopped afterward; weights were neither downloaded nor replaced.

Only `reviewed-candidate/model-proposal` and `reviewed-candidate/confined-checks`
for macOS receive supplied-identity passes (two of 90 cells). The manual served
interaction, native application launch and other configured cells remain missing;
Android/iOS/Windows/Linux remain unavailable. Numeric browser version is unavailable.
An actual browser interaction is still required beyond fetched changed JavaScript.

Reproduce the live test serially using the earlier provenance command at the exact
clean tested commit, measure the environment anew, and import both observed checks
with `tools/import_acceptance_provenance.py`. Do not reuse an old timestamp/status
for a rerun. The captured [provenance](acceptance/2026-10-28-candidate-matrix/provenance.json),
[identity](acceptance/2026-10-28-candidate-matrix/identity.json) and
[evidence](acceptance/2026-10-28-candidate-matrix/evidence.json) are the exact importer
inputs/output for this historical run. From the Flutter root, regenerate the report:

```sh
python3 -B tools/product_acceptance.py \
  --manifest docs/development/product_acceptance_manifest.json \
  --identity docs/development/acceptance/2026-10-28-candidate-matrix/identity.json \
  --evidence docs/development/acceptance/2026-10-28-candidate-matrix/evidence.json \
  --output /tmp/candidate-acceptance-report.json
```

`generatedAt` changes on regeneration; the other fields/cells must match the saved
report. Replacing the identity source revision with a different valid revision
makes both saved passes stale, leaving zero current passes. The importer only
attests supplied statuses; neither it nor a green report authenticates the run.
Paste the report in **Product acceptance evidence** to inspect its saved coverage.


## Isolated macOS build and launch (issue #271)

The [observation](acceptance/2026-10-28-macos-launch/observation.json) records
a real arm64 macOS debug build and native home-window observation from source
`e8f6f444d82dabdd9c555ac2b11033cb8132f9d6`. The only temporary build-source
change was Runner AppInfo.xcconfig: product name `ASG Acceptance 271` and bundle
ID `com.arsinha.asg.acceptance271`. The original and effective file hashes, exact
SDK/Xcode identity, executable/plist hashes and lockfile digest are recorded.
The [override values](acceptance/2026-10-28-macos-launch/build-override.xcconfig)
are evidence, not an included production configuration change.

To repeat, use a clean disposable checkout of that source revision, replace only
those two AppInfo.xcconfig values with a fresh unique acceptance name/bundle ID,
then run `flutter build macos --debug`. Open that exact built candidate, inspect
its native window and support directory, and capture fresh evidence. A unique
bundle ID separates path_provider application support and preferences from the
stable application's identity. Do not install over the stable application.
Restore the two source values after building; retain the temporary built bundle
only for audit/review.

The [actual screenshot](acceptance/2026-10-28-macos-launch/home.png) shows the
empty home, creation button and empty application-preview guidance. Native AX
inspection confirmed the same text. The unique application-support directory
contained its own 86-byte studio-v2.db. The candidate was asked to quit after
capture. No stable application bundle or existing project data was modified.

This establishes the temporary candidate's platform build and visible launch
only. No exact F10 snapshots were created, so this is neither collector input
nor a current-pass/support claim. It does not establish production-bundle launch,
create/reopen, inference, plan approval, candidate interaction, repair, Stop,
timeout or rollback. F17 remains In progress; other native targets remain untested.


## Isolated native project persistence (issue #273)

The [observation](acceptance/2026-10-28-macos-project-reopen/observation.json)
extends issue #271 using its exact temporary candidate, compiled at `e8f6f44`.
The [full bundle manifest](acceptance/2026-10-28-macos-project-reopen/bundle-manifest.json)
binds the executable, debug application dylib, Flutter assets and frameworks.
This is historical candidate evidence; no rebuild or current-main support is claimed.

Starting from its empty home, the native three-step wizard created
`My Task PlannerAcceptance 273` with no workspace folder. Through native UI,
R273 and linked queued T273 were saved at board revision 2, and `Native item 273`
was added and checked in the in-app prototype. After Quit and relaunch, the
project reopened automatically with its checked item and board. R273 was then
edited to `Native durable board edited`; a second Quit and relaunch retained
revision 3 and the same task. Process absence was verified before that relaunch.
The final candidate was asked to quit; the stable app was untouched.

Screenshots show [before restart](acceptance/2026-10-28-macos-project-reopen/before-restart.png),
[reopened prototype](acceptance/2026-10-28-macos-project-reopen/reopened-prototype.png)
and [edited reopened board](acceptance/2026-10-28-macos-project-reopen/edited-reopened-board.png).
The [saved disposable records](acceptance/2026-10-28-macos-project-reopen/saved-records.json)
corroborate the selected project, checked item and revision 3. Only synthetic
acceptance data from the uniquely identified candidate is included. Artifact
SHA-256 values and database digest are in the observation.

Repeat with a disposable unique-bundle candidate following issue #271's guide,
create a project with the wizard, save board and prototype edits, Quit, verify
the process exited and relaunch that exact bundle. Open the board and compare
the actual saved revision and prototype state; edit and repeat. Never replace
the installed stable bundle or reuse its support-directory identity.

These observations have no exact F10 input snapshot and are not collector
current-pass inputs. They establish neither inference, approved execution,
generated external output, repairs, Stop, timeout, rollback nor full F17.
Collector 17 fixtures and 22 board/session Flutter tests passed separately.


## Isolated native archive restore (issue #275)

The [observation](acceptance/2026-10-28-macos-archive/observation.json) extends
issue #273 using the same temporary unique-bundle candidate compiled at `e8f6f44`.
All 43 files still match its [bundle manifest](acceptance/2026-10-28-macos-project-reopen/bundle-manifest.json).
No new build or current-main support is claimed.

Through **Portable records**, saved synthetic records were loaded for review and
exported with the native Save dialog. The actual [version 7 archive](acceptance/2026-10-28-macos-archive/export.json)
contains board revision 3 and prototype revision 1. The Save dialog's initial
filename entry produced a colon-separated name in Documents; that synthetic file
was moved unchanged into temporary storage before import. Use the native Go to
Folder dialog to choose a temporary directory when repeating. Native typing was
needed for Flutter text fields; the initial empty-field restore attempt refused
without replacing records.

Selecting that export with the native Open dialog produced a matching preview.
Explicit restore with fresh ID `acceptance275` and name `Native Archive 275`
[succeeded](acceptance/2026-10-28-macos-archive/restore-confirmation.png). Projects
listed two workspaces. After opening the restored workspace, Quit and relaunch
retained the [checked prototype item](acceptance/2026-10-28-macos-archive/reopened-prototype.png)
and [revision 3 board](acceptance/2026-10-28-macos-archive/reopened-board.png),
including edited R273 and queued T273. App inventory omitted the candidate before
relaunch; sandbox process-list access was unavailable.

The [incompatible input](acceptance/2026-10-28-macos-archive/invalid.json) was then
selected through the native picker. UI displayed operation failed, existing
records not replaced, and no import preview/restore controls. Its invalid version
and missing fields were tested together; no single parser reason is inferred.
The [saved synthetic records](acceptance/2026-10-28-macos-archive/saved-records.json)
confirm exactly two projects, original project/records unchanged, and restored
board/prototype identical to the export source. SHA-256 artifacts and isolated
database identity are recorded in the observation. Final Quit was requested.

Repeat on a disposable unique-bundle candidate following issue #271's guide,
export a synthetic project, preview and restore with a fresh ID, reopen it after
Quit/relaunch, compare the board/prototype and original project, then select an
incompatible archive and verify no new workspace appears. Never reuse stable
app storage or replace its bundle. These historical observations lack exact F10
snapshots and are not collector current-pass input. No inference, generated
external output, approved execution, repair, Stop, timeout or rollback is claimed.
The 98 archive/session Flutter tests and 17 collector fixtures passed separately;
F17 remains In progress.


## Native offline Plan boundary, 29 October 2026 (issue #277)

The [sanitized observation](acceptance/2026-10-29-native-offline-plan/observation.json) records actual native UI execution on the existing isolated acceptance candidate compiled at e8f6f44. The loopback runtime was offline: Plan reported failure, discarded partial response and exposed no approvable model draft. A Build attempt with separate operation consent stopped with current Plan guidance; no output folder or approval record appeared. Restart retained the checked prototype and requirements revision3. All43 bundle files matched the previously delivered manifest; durable records changed only by the synthetic user request. Raw request/database are retained locally and are not shared artifacts.

Run the existing Plan approval, diagnostic and planning conversation tests plus `tools/test_product_acceptance.py` for deterministic regressions (26 passed/one opt-in skipped and17 passed for this increment). The UI observation is historical caller-attested evidence, not an exact F10 collector input or current-main support claim. Blank SDK input means the generic Build error alone does not isolate Plan as the cause; matching controller gate ordering and absent approval/output corroborate the refusal boundary. No successful Plan, requirements-change invalidation, inference, generated output, repair, Stop, timeout, rollback or preexisting external last-working preservation is established. F17 remains In progress.


## Native Plan approval and Discuss Stop observations (issue #279)

The [Plan observation](acceptance/2026-10-29-native-plan-stop/plan.json)
and [Stop observation](acceptance/2026-10-29-native-plan-stop/stop.json)
record earlier real native interactions on the isolated candidate compiled at
`e8f6f444d82dabdd9c555ac2b11033cb8132f9d6`, with its distinct
`com.arsinha.asg.acceptance271` identity. These are operator observations, not a
fresh current-main app build or collector inputs. All 43 existing bundle-manifest
entries and both retained database hashes were rechecked for this delivery.

With the already installed offline Qwen MLX runtime Ready, Plan visibly streamed
and completed four validated fixed-starter tasks. Explicit approval survived Quit,
verified process absence and relaunch. Editing the synthetic project's requirements
made that approval outdated; a separate consented Build stopped with current Plan
guidance and created no output. This establishes a historical refusal boundary,
not successful generation or arbitrary source synthesis.

In a later Discuss interaction, Thinking and Stop appeared. Clicking Stop restored
the idle composer and displayed partial-response discard with saved messages
retained. Quit/relaunch retained the previous three messages plus the submitted
user request; no new assistant response was saved. The
[digest-only persistence comparison](acceptance/2026-10-29-native-plan-stop/persistence.json)
confirms that between the retained Plan and Stop snapshots only that chat record
changed, its first three messages remained exact, and the appended message was a
user message. The snapshots are Sembast JSON-lines records, not SQLite databases.
Raw databases, approval/model response text and requests remain local.

To repeat, use a disposable unique-bundle candidate/profile as in issue #271 and
the existing offline runtime as described in QWEN_STREAMING.md. Complete Plan in
the synthetic project, explicitly approve, Quit and verify process absence, then
relaunch and inspect approval. Change project requirements and verify stale
approval and Build refusal after separate operation consent. For Discuss Stop,
focus the composer, observe focus, enter a synthetic request in a separate action,
submit, wait for Thinking/Stop, and click Stop. Verify diagnostics, prototype and
saved records after Quit/process absence/relaunch. Compare durable records and
rehash the exact bundle; retain prompts and raw storage privately. Stop only the
runtime owned by the test.

Current-main regression tests are recorded separately from the historical UI
source in these observations. Neither persistence hashes nor passing fixtures
prove the earlier UI state independently. No server-side cancellation, generated
output Stop, timeout, rollback, exact F10 identities or current support is claimed.
F17 remains In progress. Issue #277 / PR #278 was independently reviewed at
`a6dcd4ebc533b0267475538f1b0d5a21c5c7f899`, required CI 40829818290 passed,
and merged as `48c5bf26b12dbaf60835ecd374c31e10fe549b2c` on 29 October 2026;
its earlier offline-refusal observation remains distinct.


## Native runtime connection-test timeout (issue #281)

The [sanitized timeout observation](acceptance/2026-10-29-native-runtime-timeout/observation.json)
records the prior 29 October native interaction on isolated candidate
`e8f6f444d82dabdd9c555ac2b11033cb8132f9d6`. All 43 files still match the
linked bundle manifest. This is an operator-attested historical UI observation,
separate from current-main deterministic regressions.

An owned loopback-only HTTP fixture accepted the Test inference POST, discarded
its body without logging it, and withheld the response for 40 seconds. The native
form showed an active wait and Stop test, then displayed “Connection test timed
out. Check the runtime and retry.” Idle controls returned. Connect & save was
never invoked; the original unsaved URL was restored before leaving the form.
Back in the workspace, prototype v1 and its checked item remained visible. The
candidate was quit and its absence confirmed; the owned fixture exited cleanly.

To repeat, use the disposable unique-bundle profile described above. Start an
owned HTTP server bound only to `127.0.0.1` on an unused port: its POST handler
reads and discards the request body, logs only that POST was accepted, waits 40
seconds, then closes without a response. GET may return 503. In Runtime settings,
replace the unsaved endpoint with that loopback address, verify the text actually
changed, and select Test inference. Observe waiting, timeout guidance and restored
controls. Restore the prior unsaved endpoint without Connect & save, return to
the workspace and inspect the existing synthetic prototype. Quit the candidate,
verify absence and stop only the fixture owned by the test.

No fresh model inference occurred. The observation has no screenshot, raw
persistence comparison, exact F10 input identity or current-support verdict.
Transport startup timeout does not establish generated-output timeout, rollback,
server-side inference cancellation or external last-working-output preservation.
F17 stays In progress.


## Native verification Stop and explicit retry (issue #283)

The [sanitized observation](acceptance/2026-10-29-native-verification-stop/observation.json) records actual interaction on the historical isolated acceptance271 candidate compiled at `e8f6f44`. All43 retained bundle files matched. A real current fixed-starter Plan was explicitly approved; separate generation consent created a disposable starter. Resolve passed, Stop cancelled running analysis, and downstream test/build became blocked. The failed outcome retained files. Explicit full retry passed all four steps. The actual served output accepted a new task and checkbox change; after native Quit/absence/relaunch, the original prototype remained and expanded build history retained both failed and ready records.

Repeat in an isolated profile/project: explicitly start the already installed local runtime, request/review/approve a current fixed-starter Plan, open Generate, supply a NEW disposable destination and installed SDK, and grant operation consent. After resolve passes and analysis starts, choose Stop verification and wait for the saved failure. Check cancelled/blocked results before choosing the explicit full retry. After all four checks pass, start the actual preview, open its loopback link, add/check a synthetic task, then stop preview and quit. Confirm application absence, relaunch, and inspect saved ready/check results plus both history entries. Never overwrite an existing output to reproduce this scenario.

Current-main regressions:70Flutter generation/history/rollback tests and17collector fixtures passed separately. Native results remain historical observations, not current-main support or exact F10 evidence. There was no previous external successful build before Stop, so external last-working preservation is unverified; generated timeout, selected rollback and model candidate/repair interaction remain pending. Browser task persistence was not assessed. Raw requests, model text, storage, screenshot and private preview URL remain local; only digest linkage is published.


### Historical native selected rollback (29 October 2026)

Issue #285 adds [sanitized observations](acceptance/2026-10-29-native-selected-rollback/observation.json) for the same historical acceptance271 bundle. A distinct generation stopped during web build; the prior verified external output remained hash-identical. Explicit selected rollback served it, actual add/check interaction passed, and native restart retained ready selection plus failed history. Displaced source files and failed record remain. All43 bundle files matched;70 current-main Flutter regressions and17 collector fixtures passed separately. This does not establish current support, exact F10 provenance, generated timeout, model candidate/repair acceptance or browser persistence. Raw DB/screenshot remain local.


### Real Plan lifecycle coverage (issue #287)

The `approved-plan` scenario now includes manual check
`plan-lifecycle-interaction` on macOS and web, alongside the existing
`stale-plan-refusal` fixture. Fixture success covers only its own cell; it cannot
cover actual approval or stale-approval refusal in the running application.

In a disposable profile on each target, create requirements and tasks, request
a real Plan, inspect the completed task mapping and explicitly approve it. Quit
and relaunch (or reload the web app), then confirm approval remains current.
Change requirements and confirm that the saved approval becomes outdated. With
separate operation consent, attempt Build and observe refusal before any new
generation writes; preserve existing source and last-working output. Record all
of these observations before marking this manual check passed. Missing model,
toolchain or any unobserved step means unavailable, skipped or failed evidence
as appropriate, never a pass inferred from fixture results.

Use the existing caller-attested provenance collector workflow to bind fresh
observations to exact requirement/input/source and measured environment identity,
UTC time and bounded sanitized artifact digests. The collector validates identity
and freshness; it does not inspect artifacts or certify the operator's claim.
Historical #279 observations remain historical and are not promoted to current
passes. The manifest digest changes, so prior saved records become stale against
this manifest until their checks are rerun and collected. Historical reports and
IDs are retained. This increment adds coverage, not new product-support evidence.


### Native Plan and candidate interaction (issue #289)

[Sanitized observations](acceptance/2026-10-29-native-plan-candidate/observation.json)
record actual isolated0954 interactions compiled at `91262e8`, with all43 bundle
files verified against the included manifest. A real offline MLX starter Plan was
explicitly approved and remained approved after native restart. A saved acceptance
edit invalidated it; old-draft reapproval was disabled and consented Build refused
before output writes. No prior external working output existed during that refusal.
A subsequent version4 mapped Plan produced a separate starter whose four checks
passed. The first view-file model proposal failed safely; a main-file retry produced
a reviewed formatting-only diff. Its claimed syntax fix was not established.

The explicit separate candidate passed confined resolve/analyze/test/build; explicit
promotion served actual add-item/checkbox interaction. Native restart restored the
promoted ready directory and checked prototype item, with operation consent reset.
The original starter's13source/34output files remained hash-identical. These are
caller-attested observations, not exact F10 collector inputs or current support.
Browser persistence, real repair and generated-output timeout remain unobserved.

Repeat with the isolated unique-bundle/profile procedure above and existing offline
model. Save a requirement/task, request/review/approve a starter Plan, restart, edit
acceptance and attempt Build with valid paths and separate consent; verify no output
writes. Request a fresh version4 Plan mapping every operation to an existing task.
Generate into a new empty parent, run all checks, select a recorded small Dart file,
request and inspect its full diff, choose a separate candidate parent, prepare,
explicitly consent to confined checks, then separately promote. Interact with the
served output beyond its title, restart native ASG and inspect its saved working
selection. Compare original source/output hashes before and after; retain failed
results honestly. Never interpret model summary text or generic builds as criterion
verification. No source implementation changed in this evidence increment.


## Native repair and generated-check deadline (issue #291)

The [sanitized observation](acceptance/2026-10-29-native-repair-timeout/observation.json)
and [saved command summaries](acceptance/2026-10-29-native-repair-timeout/native-checks.json)
record actual isolated native UI interactions at compiled revision `91262e8`.
All43 bundle hashes matched. Application/test/tool sources are unchanged through
plugin-verified main `1f4b768`, the source used for the separate automated test.
Raw database records, model prompts, private logs and preview capability URLs stay local.

To reproduce on an isolated unique-bundle profile with a ready working build:

1. Save original source/output hashes. Use an explicitly identified loopback fixture
   to supply a full-file proposal adding a five-minute asynchronous test, with
   `timeout: const Timeout(Duration(minutes: 10))`. Keep existing tests. Review and
   prepare a separate candidate, then consent to confined verification. The longer
   per-test timeout is necessary: without it Flutter stops at30seconds, which does
   not establish ASG's command deadline.
2. Observe resolve/analyze pass, followed by the180-second command deadline.
   Confirm saved test exit-1/timedOut=true, no output-limit/cancel flag, intervention
   diagnosis, no source-repair action and no promotion. Preserve this failed journal.
3. Return to the unchanged working source. Supply a separately reviewed deterministic
   main-file proposal inserting only `asgMissingFunction();` immediately before
   `runApp`. Verify it separately and inspect the actual undefined-function analyzer
   output. These faulty seed proposals are fixtures, not successful model inference.
4. Restore real transport to the existing offline Qwen3.5-9B MLX runtime. Select a
   separate parent folder, consent to bounded automatic repair for main only, and
   start. Confirm actual model correction removes only the undefined call, one
   analyze request is saved, and resolve/analyze/test/build all rerun and pass.
5. Explicitly promote the verified candidate. Open its actual served app, add an
   item and check it; verify the original checked item remains. Quit native ASG,
   verify absence, relaunch and inspect restored ready directory, four passed checks
   and saved analyze1/3 budget. Compare original source/output hashes again. Stop
   owned app, fixture and runtime. Do not infer browser persistence from this test.

A separate existing `automatic_repair_real_test.dart` run passed in61seconds at
`1f4b768`, including saved failure, real correction, confined rerun, promotion,
preservation and database reopen. Its [exact F10 linkage](acceptance/2026-10-29-native-repair-timeout/repair-provenance.json),
[measured identity](acceptance/2026-10-29-native-repair-timeout/repair-identity.json),
[configuration](acceptance/2026-10-29-native-repair-timeout/repair-configuration.json),
[evidence](acceptance/2026-10-29-native-repair-timeout/repair-evidence.json) and
[report](acceptance/2026-10-29-native-repair-timeout/repair-report.json) form a reproducible
historical submitted observation. Use the existing collector command above with
these identity/evidence files to regenerate; only generatedAt changes.
The report supplies only the macOS bounded-repair cell. It does not relabel native
UI interaction as F10-derived evidence or fill missing/unavailable cells.

104focused Flutter regressions and20collector fixtures also passed. No application
implementation changed or fresh platform build was needed locally; required CI
still gates the evidence PR. Numeric browser version remains unavailable because
browser policy refused version-page inspection. F17 remains In progress for the
complete exact-identity macOS/web baseline; this closes the previously unobserved
native repair/deadline slice only after independent review and verified merge.


## Web native-generation boundary (issue #293)

Run from the Flutter root with the installed Chrome browser:

```sh
flutter test --no-pub --platform chrome test/browser_generation_capability_test.dart
```

This automated browser test compiles the production conditional host factory;
it does not inject a fake native host. It verifies that generation, verification
(including resume), preview startup and preview opening report unsupported without
write-authorization or progress callbacks. The actual Build view shows the macOS
host requirement, disables local directory pickers and keeps Generate disabled
even after explicit operation consent. Controller calls cannot start generation,
retry, resume or preview. A uniquely named disposable IndexedDB database retains
exact saved prototype/build bytes and prototype revision across close/reopen,
then is deleted. External IndexedDB work uses the widget tester's real async
zone; simulated widget time must not stand in for durable completion.

The required Chrome CI step runs this test alongside storage/archive checks.
A passing browser regression establishes this unavailable-host boundary only.
It is neither a manual browser workflow nor a native generation, live model,
repair, served generated-output or current-support pass. Existing web prototype,
records and model-connection features remain distinct from the unavailable local
filesystem/Flutter runner. Do not convert this result into passed generation
cells in a collector report or invent F10 snapshot identities from fixture text.
The complete exact-identity F17 macOS/web matrix remains pending.


## Exact-snapshot web reopen extension (reused issue #265)

The [observation](acceptance/2026-10-29-web-reopen-matrix/observation.json)
and [displayed F10 snapshot](acceptance/2026-10-29-web-reopen-matrix/f10-snapshot.json)
record actual isolated-origin Chrome create/reopen at source `87d8cb4b7bdda9ad49327f00124731e29b7c55a3`.
The [saved report](acceptance/2026-10-29-web-reopen-matrix/report.json)
contains only three supplied web observations: release build, application launch
and manual create/reopen. It is historical caller-attested evidence, not current
support. Browser numeric version is unavailable. Input/model hashes use the
explicit UTF-8 `unavailable` sentinel because there was no approved run or model;
the actual unapproved current F10 input digest is retained separately. Do not use
this sentinel as approved-plan/build/inference provenance. The board hash comes
unchanged from the displayed F10 snapshot. All other checks remain missing or
unavailable; full F17 stays In progress.

Repeat on a fresh loopback origin using a current release web build. Create a Web
daily task planner named Exact web baseline; add RBASE with title Exact browser
reopen and acceptance The saved board and checked prototype item survive reload
and explicit reopen. Add queued TBASE, Verify browser persistence, linked to
RBASE. Add and check Identity-bound saved item in the prototype. Reload, then
Projects → explicitly reopen and verify board/task/item. Edit RBASE to Edited
exact browser reopen with acceptance Edited acceptance and linked task survive
reload; checked prototype remains intact. Await the visible revision3 save
acknowledgment before reloading. Verify exact edited text/task/checked item.
Open Requirement check report → Exact saved revision and results; capture that
displayed JSON, retaining absent saved run/source/input/approval as absent.
The fresh origin isolates storage, not a separate browser profile. Stop only the
owned tab/server; the stable app remains untouched.

Regenerate from Flutter root with the existing collector:

```sh
python3 -B tools/product_acceptance.py --manifest docs/development/product_acceptance_manifest.json --identity docs/development/acceptance/2026-10-29-web-reopen-matrix/identity.json --evidence docs/development/acceptance/2026-10-29-web-reopen-matrix/evidence.json --output /tmp/asg-web-reopen-report.json
```

The generatedAt value changes on regeneration; all other fields must match.
Changing source, board, input, configuration or device identity makes allthree
supplied records stale. The evidence revision deliberately remains the tested
application source after these observation documents merge.


## Browser source-candidate refusal extension (reused issue #293)

The actual Chrome suite in `test/browser_generation_capability_test.dart` also exercises the public `prepareSourceCandidate` conditional import with current persisted approval and matching generated-input fingerprints. It must fail specifically because the browser lacks a native filesystem, after current-authority validation. It checks exact saved project/requirements/conversation/approval/prototype/working-generation records before and after refusal and IndexedDB reopen. Withdrawn approval must instead fail current-authority validation and retain its exact withdrawn record through reopen. The disposable database is removed afterward.

This is automated unavailable-boundary coverage. No model request, candidate file creation, confined verification, promotion, served output interaction or manual acceptance pass is established. Full F17 remains In progress. Run the same required Chrome command documented above; no separate browser CI registration is needed.


## Exact-snapshot native reopen extension (issue #273)

The [native evidence directory](acceptance/2026-10-30-native-reopen-matrix/observation.json)
records a bounded current-source persistence observation, extending delivered PR #274.
The uniquely identified debug bundle used source `422363fc04db6a20b6c515c25dc71f4becaafff6`:
504 tracked files matched, with only the retained app-name/bundle configuration override.
The bundle manifest, effective configuration and sanitized device identity are retained.
This run reused the earlier build; it does not assert a fresh build pass.

Using the isolated application, edit RNATIVE's title, wait for revision3 acknowledgement,
expand Requirement check report → Exact saved revision and results, and capture the
rendered JSON. Explicitly quit and verify absence, relaunch that same isolated app path,
observe the checked prototype item, open the board and capture its exact report again.
The retained before/reopened JSON documents compare equal. The actual title contains
an appended suffix because the automation's select-all did not replace the original;
no product defect or successful replacement is inferred. Final app exit was verified.

Only native `create-reopen/interactive-reopen` is supplied as a caller-observed pass.
Initial creation was observed by the preceding run; this run verifies durable edits
and reopen of that project. There is no approved source run or model request; their
collector identities use SHA-256 of UTF-8 `unavailable`, while the actual current
unapproved input remains in the F10 snapshots. No full F17/support claim follows.

From the Flutter root, regenerate the exact report (the original generatedAt is
retained as the deterministic comparison time when using the Python API):

```sh
python3 -B tools/product_acceptance.py --manifest docs/development/product_acceptance_manifest.json --identity docs/development/acceptance/2026-10-30-native-reopen-matrix/identity.json --evidence docs/development/acceptance/2026-10-30-native-reopen-matrix/evidence.json --output /tmp/native-reopen-report.json
```

Only generatedAt changes on a later CLI run. Source, requirement, input, configuration
or device identity mutation makes the supplied cell stale. All other cells stay
missing or unavailable; saved caller observations are not authenticated acceptance.


## Native exact-snapshot archive interaction (issue #275 extension)

The [observation](acceptance/2026-10-30-native-archive-matrix/observation.json)
records native export, separate restored workspace and retained revision3 board/
checked prototype across explicit Quit, verified absence and path relaunch.
The [export](acceptance/2026-10-30-native-archive-matrix/export.json) is synthetic
version7 data. Version999 import was refused. Original remains listed; no
post-restore database byte-equality check is claimed. Source422363fc bundle was
reused, with all43 bundle hashes and300 selected source/test/tool/platform files
verified against both source snapshot and reviewed branch. Only the unique
app-name/bundle override differs. No new build, inference or support claim.

The two F10 files transcribe separately expanded rendered JSON using the prior
identical structure and actual restored current-input digest. They compare equal
across restart. Their board matches the original, while restored project metadata
changes current-input identity. Saved approved input/model remain unavailable;
collector identities use explicit sentinel digests, not the unapproved input.
No screenshots are retained by this extension. UI control lag and native Save
filename behavior are documented in the observation rather than hidden.

Repeat on the isolated bundle/profile: portable records → load/review/export;
select actual saved file → restore a unique new ID/name; verify both Projects
entries; open restored prototype/board/report and retain full displayed F10 JSON;
Quit, separately verify absence, relaunch path and repeat; select incompatible
fixture and verify no restore offered. Never use stable application storage.
The saved report supplies only native archive-interaction. Regenerate from Flutter
root (other scenarios remain missing/unavailable):

```sh
python3 -B tools/product_acceptance.py --manifest docs/development/product_acceptance_manifest.json --identity docs/development/acceptance/2026-10-30-native-archive-matrix/identity.json --evidence docs/development/acceptance/2026-10-30-native-archive-matrix/evidence.json --output /tmp/native-archive-report.json
```

105 focused Flutter archive/store/controller/session/report tests and20 collector
fixtures passed. All six identity changes stale the submitted observation. These
are caller-attested records, not live health/authenticity or complete F17 acceptance.


Delivery [PR #298](https://github.com/arpit-it/ASG/pull/298): initial published `382c0c50d52a34d29d7dca9f838e71f50759525d` / tested local `2984ba2091acd1fd258697c24e749b1a626af9fb`, identical tree `ca2c570796d1846e0a5f0103145408151ef2b6ff`. This delivery-link revision changes documentation only. Extension Awaiting independent exact-final review/required CI/merge; final head and merge evidence must be verified on the PR. Full F17 stays In progress.


### Exact-snapshot native Plan lifecycle and preservation (issue #287 extension)

The [sanitized observation](acceptance/2026-10-30-native-plan-matrix/observation.json) records actual isolated native Plan approval, Quit/relaunch durability, requirements invalidation, separately consented Build refusal and last-working preservation. The [ready snapshot](acceptance/2026-10-30-native-plan-matrix/f10-working-reopened.json) and [stale snapshot](acceptance/2026-10-30-native-plan-matrix/f10-stale.json) are exact expanded F10 JSON. A fresh real offline mapped Plan authorized a disposable starter whose four checks passed. After restart and requirement revision5, a new Build refused; the working record and57 checked files (including all12source/34output F10 hashes) remained identical. The collector [evidence](acceptance/2026-10-30-native-plan-matrix/evidence.json) and [report](acceptance/2026-10-30-native-plan-matrix/report.json) supply only the native Plan manual cell.

Repeat in the disposable uniquely identified candidate: open Plan with the existing offline runtime, request a version4 fixed-starter contract mapping resolve/analyze/test/build to an existing task, inspect it and explicitly approve. Grant separate generation consent for an unused temporary destination with the installed SDK; require four real successful checks. Retain the exact F10 ready JSON, approval/generation records and generated source/output hashes. Explicitly Quit, independently confirm absence, relaunch the same bundle path and verify current approval. Edit requirements and save a new revision, retain expanded stale F10 JSON, then grant separate Build consent for a different unused destination. Require refusal, unchanged working records/source/output and absence of the new destination. Stop the owned runtime and Quit the candidate. Never replace the stable app.

Reproduce the report from the Flutter root using `python3 tools/product_acceptance.py --manifest docs/development/product_acceptance_manifest.json --identity docs/development/acceptance/2026-10-30-native-plan-matrix/identity.json --evidence docs/development/acceptance/2026-10-30-native-plan-matrix/evidence.json --output /tmp/asg-plan-report.json`. The generatedAt value changes; all other data should match. Changed source/board/input/configuration/model/device makes this record stale. Source422363fc is the actual compiled snapshot;300selected tracked files match tested mainb52022d and all43bundle hashes match the retained build. This is historical supplied-identity manual evidence, not a current-main certification or full F17 completion. No served-output interaction or browser Plan lifecycle is claimed. Raw prompts, database and screenshots remain local; shared artifacts contain synthetic requirements/contracts and sanitized diagnostics only.


## Separate Stop and generated-command deadline coverage (#283 extension)

The `stop-preservation` scenario now requires separately saved manual
`stop-interaction` and `deadline-interaction` records per target. Its retained
`stop-and-timeout` check is combined-workflow evidence, not a source of inferred
passes for either individual check. Record the combined check only after both
behaviors and last-working preservation are observed under that exact identity.
A Stop-only observation leaves the deadline and combined cells missing; a deadline
observation leaves Stop and combined missing. No fixture or F10 importer maps to
these manual checks. Historical JSON snapshots are unchanged; the expanded
manifest makes their records stale until the affected workflow is observed again.

For Stop, begin with a retained successful output and hashes, approve a disposable
verification run, choose Stop while a generated command is running, and inspect
its saved cancellation and blocked downstream results. Require no promotion,
unchanged last-working source/output and a usable served previous output. Quit,
confirm absence, reopen the same isolated bundle and inspect retained results.

For the deadline, independently run an explicitly reviewed disposable candidate
with a controlled test delay longer than ASG's generated-command deadline and a
Flutter per-test timeout longer than that deadline (see the #291 instructions
above). Wait for ASG's saved `timedOut` outcome; a Flutter test timeout, runtime
connection timeout or user Stop cannot satisfy this check. Require blocked
downstream work, no inappropriate repair/promotion, unchanged last-working
source/output, usable served previous output and saved results after reopen.

Retain separate bounded artifacts and UTC observations for each run, including
actual command flags/results and preserved hashes. Bind every record to its own
exact source, requirement/input, SDK/runtime/model/configuration and device/browser
identity. Do not relabel historical observations as fresh or combine different
snapshot identities into current support. This collector increment performs no
new native/model workflow; full F17 remains In progress.


## Native manual repair interaction — reused #291

The [observation](acceptance/2026-10-30-native-repair-interaction/observation.json)
records the retained compiled584c89c native workflow: explicitly reviewed deterministic
Plan/undefined-call seed, actual analyzerfailure, separately consented real offline
Qwen repair, four confined reruns, explicitpromotion, actual servedChrome add/check,
Quit/independentabsence/relaunch and retained ready build/approval/repairbudget.
Only `bounded-repair/repair-interaction` onmacOS is submitted. Baseline44source/output
hashes and18priorrecords remain unchanged.300source/43bundle/sevenmodel hashes
were verified. No runtimecode changed, fullF17 or current-main rebuild claim.

Repeat in a new disposable isolated workspace: author RREPAIR/TREPAIR with acceptance
removing only undefined asgMissingFunction inlib/main.dart while preserving all other
code. Explicitly review/approve the clearly labeled fixture Plan; generate a fresh
fixed starter and require four0checks. Select onlymain, review the deterministic
undefined-call insertion, prepare separate candidate and consent confinedverification.
Require actual undefined_function analyzer1; never promote. Select temporary repair
parent, connect existing offlineQwen through the real-only loopbackrelay and explicitly
consent bounded automaticrepair. Require exactly observed saved attempts andfour0checks,
unchanged working files/records; explicitlypromote. Open actual servedapp, add/checkitem.
Quit and independentlyconfirmabsence, relaunchexactbundle, inspect readyfolder/approval/
fourchecks/repairbudget. Preserve originalprojects andstableapp; stopownedprocesses.

The retained fixture summary says deadline because it was adapted from the prior
workflow; the actual selected full diff contains only the undefined-call insertion.
No delay or deadline acceptance is asserted. Standard native GoTo and Flutter AX text
can differ from controller state; verify actual chosenparent and durablevalues rather
than trusting a changed AXstring. Attemptstatus retains proposal-unverified wording;
its separate finished ready run establishes reruns. Browserversionunavailable and
browseritempersistence are not claimed. RawDB/prompt/logs remain private.

Regenerate from Flutterroot using the existing collector with current manifest and
this directory's identity/evidence; only generatedAt changes. The report is a saved
caller-attested observation, not authentication or a support certification.


## Current-manifest web archive interaction — issue #267 extension

The [observation](acceptance/2026-10-30-web-archive-matrix/observation.json)
records a fresh source4787d944 release build and actual browser workflow on a new
loopback origin: app-led original creation, revision2 RARCHIVE/TARCHIVE, checked
prototype, actual export/download, picker import and separate restore, reload,
version999 refusal, second reload and original reopen. Both rendered F10 snapshots
compare exactly. Source167files/bundle44files have SHA256 manifests. The original
and restored projects remain distinct; no database byte-equality claim is made.

Repeat with a fresh `flutter build web` at the recorded source, serve build/web
on an unused loopback port and keep that origin across reloads. Use only synthetic
records. Wait for visible revision/save acknowledgment. Export via Portable records,
inspect the actual downloaded JSON, import through Select archive file, choose a
new ID/name and explicitly restore. Open through Projects, reload, inspect checked
prototype/board and expand the exact F10 report. Click the rendered selectable JSON
if accessibility initially omits its text. Import version999 and verify refusal,
then reload/reopen and compare the actual exact report; original must remain usable.
Stop the owned server and close the owned tab.

Regenerate with `python3 tools/product_acceptance.py --manifest docs/development/product_acceptance_manifest.json --identity docs/development/acceptance/2026-10-30-web-archive-matrix/identity.json --evidence docs/development/acceptance/2026-10-30-web-archive-matrix/evidence.json --output /tmp/web-archive-report.json`.
Only generatedAt changes. The saved report has exactly one caller-observed manual
web archive cell; other cells stay missing/unavailable. Model and approved-input
identities use UTF8 unavailable; current unapproved input remains in exact F10 JSON.
The host was remeasured macOS27.0.1/arm64; browser numeric version unavailable.
A fresh origin separates storage, not browser profiles. No inference/native source
generation, compatibility certification or full F17 completion follows.


## Native fixture baseline — issue #253 extension

The [observation](acceptance/2026-10-30-native-fixture-baseline/observation.json) records44 actual native VM fixture tests across the four manifest-referenced storage, Plan approval, rollback and archive suites at source35a9088b.27 Python collector/importer/CLI fixtures passed separately. These runs establish four saved macOS fixture cells only. They do not establish native app launch, generated output, model inference, browser behavior or manual acceptance. All other116cells remain missing/unavailable. FullF17 remains In progress.

Repeat from a clean checkout of the recorded source using Flutter3.47.6/Dart3.13.5 on macOS: `flutter test test/transactional_storage_test.dart test/plan_approval_test.dart test/build_rollback_test.dart test/portable_project_archive_test.dart --reporter expanded`, then `python3 -B tools/test_product_acceptance.py`. Verify actual exits/totals before collecting new evidence; never relabel these observations after a source/toolchain/configuration change.

The suites use multiple disposable project snapshots, so no single F10 requirement/input identity exists. Those fields and model use SHA256 of UTF8 `unavailable`; runtimeVersion denotes absent model runtime, with actual Dart version in configuration. No F10 criterion is verified by this fixture identity. Source manifest lists tracked runtime/test/platform/tool files and their exact SHA256 at the tested commit. Config/device hashes use the collector canonical JSON function; artifact hashes use exact file bytes.

Regenerate with `python3 tools/product_acceptance.py --manifest docs/development/product_acceptance_manifest.json --identity docs/development/acceptance/2026-10-30-native-fixture-baseline/identity.json --evidence docs/development/acceptance/2026-10-30-native-fixture-baseline/evidence.json --output /tmp/asg-fixture-report.json`. Only generatedAt changes. Source, requirement, input, configuration, model or device identity changes make all four cells stale. Observations remain caller-attested saved results, not support certification.


## Chrome Plan approval persistence fixtures — issue #287

The [repeat instructions](acceptance/2026-10-30-web-plan-fixture/REPRODUCE.md) and
[saved report](acceptance/2026-10-30-web-plan-fixture/report.json) record actual
IndexedDB close/reopen approval validity and refusal after requirements,
prototype revision or latest Plan changes. Four Chrome tests passed, including
three new lifecycle regressions, plus durable withdrawal and raw corrupt
approval preservation. This supplies one web approved-plan fixture cell only.
No manual Plan UI, model request, app launch or full F17 acceptance is inferred.
The manifest now references the browser suite alongside native approval tests;
older observations retain their historical manifest identity.


## Browser rollback record fixtures — issue #253

[Repeat instructions](acceptance/2026-10-30-web-rollback-fixture/REPRODUCE.md) record two actual Chrome IndexedDB tests for selected saved history, atomic previous/current pointer preservation, stale durable compare-and-set refusal, withdrawn authorization and corrupt raw history preservation. Only one web rollback-records fixture cell is supplied. Synthetic artifact hashes do not validate files, native preview or manual rollback; full F17 remains In progress.


## Browser durable-records fixture — issue #253

[Repeat instructions](acceptance/2026-10-30-web-durable-fixture/REPRODUCE.md) record five actual Chrome tests including one new edited-project/conversation/requirements persistence regression. Two IndexedDB reopens, unrelated-record isolation, malformed-write refusal and raw durable transaction-abort preservation supply one web create-reopen/durable-records fixture cell only. Manifest now references the browser suite alongside native storage coverage. No manual UI, application launch/build, inference or fullF17 acceptance is inferred.


## Native deadline restart and served-output supplement

The [follow-up observation](acceptance/2026-10-30-native-deadline-reopen/observation.json) adds actual preserved-preview add/check and Quit/independent absence/relaunch facts to PR307. All57 working files and all durable record values remained unchanged across restart. Retained compiled300source/43bundle manifests were checked. The failed timedOut candidate is present in durable records; reopened source-review UI does not expose its prior details. [Repeat instructions](acceptance/2026-10-30-native-deadline-reopen/REPRODUCE.md) preserve the distinction. No deadline rerun, new matrix pass, Stop/combined/model/current-main/fullF17 claim.


## Isolated native build/launch matrix — issue #271

[Repeat instructions](acceptance/2026-10-31-native-launch-matrix/REPRODUCE.md) record an actual debug build at source6ea5f428 and observed fresh native home in a unique test bundle, migration-only storage and native Quit/independent absence.301source/43bundle file digests and measured identities accompany exactly two saved macOS application-baseline cells. Initial elapsed time included approval waiting; a single reset/reconnect succeeded. No startup-performance, full-workflow/model/current-support or fullF17 claim follows.


## Exact F10-context web Plan lifecycle — issue #287

The [observation](acceptance/2026-10-31-web-plan-matrix/observation.json) and
[saved report](acceptance/2026-10-31-web-plan-matrix/report.json) record one actual
web `approved-plan/plan-lifecycle-interaction` cell at compiled main aa79c4e3.
A fresh release web build, unique loopback origin and existing offline MLX model
produced a validated fixed-starter Plan with resolve/analyze/test/build all mapped
to saved task TWEB. Explicit approval survived reload. Editing RWEB to revision3
made it outdated, disabled reapproval and survived a second reload. Browser
Generate remained disabled even after separate operation consent, then consent
was cleared. This observes a UI boundary, not an executed native stale-plan gate.

Repeat on a fresh loopback origin. Create a Web daily task planner named Exact web
Plan baseline. Save RWEB, title Browser Plan approval lifecycle, acceptance Saved
Plan approval survives reload and becomes outdated after requirements change.
Save TWEB, title Verify browser Plan lifecycle, linked to RWEB. Request a version4
fixed-starter contract mapping every operation to TWEB using the existing local
Qwen runtime. Inspect all validated mappings, explicitly approve, reload, reopen
Plan and confirm approval. In Requirements and tasks open Requirement check
report, expand Exact saved revision and results and retain the actual JSON.
Edit RWEB title to Browser Plan approval lifecycle revised, save, reopen Plan,
confirm outdated/disabled reapproval, reload and verify again. Retain the second
expanded F10 JSON. Observe the disabled native generator with and without consent;
clear consent. Close only owned tabs/processes. Never replace the stable app.

The exact [approved-context snapshot](acceptance/2026-10-31-web-plan-matrix/f10-approved-reloaded.json)
and [changed-context snapshot](acceptance/2026-10-31-web-plan-matrix/f10-changed-reloaded.json)
retain F10's null saved run/source/input/approval fields. The collector identity
uses the initial board digest and exact displayed **currentInputSha256** of the
prototype/project. It does not use a generated-run input or imply a saved
verification. This manual Plan lifecycle needs no generated project in an
unsupported browser host. Current input stays unchanged while board revision and
digest change. No automated F10 criterion verdict is claimed.

Regenerate using `python3 tools/product_acceptance.py --manifest docs/development/product_acceptance_manifest.json --identity docs/development/acceptance/2026-10-31-web-plan-matrix/identity.json --evidence docs/development/acceptance/2026-10-31-web-plan-matrix/evidence.json --output /tmp/web-plan-report.json`.
Only generatedAt changes. Six source/board/input/config/model/device mutations
make the sole saved pass stale. Source, bundle and remeasured model manifests
bind the tested identities. Later source/manifest changes remain stale; do not
relabel this as current-main support. Raw screenshots stay local; sanitized
observation records expose only digests and synthetic F10 snapshots. No model
weights/prompts/database/runtime paths are published. Full F17 remains In progress.


## Per-check platform scope — issue #293

A check may optionally declare `targets`, a nonempty unique subset of its
scenario targets. Omission preserves the version-1 scenario-wide default. The
collector marks every other target unavailable and rejects supplied evidence for
it, including passed observations. This is configured execution scope, not an
observed test pass or automatic hardware detection.

The current browser has no native generated-project host. Candidate proposal
and verification, repair, generated-output Stop/deadline and selected rollback
interaction checks therefore target macOS only. Browser Plan lifecycle,
create/reopen, archive, rollback record fixtures and application checks remain
configured. With the browser-only archive fixture scope below, the empty120-cell
matrix has19 missing macOS cells,10 missing web cells and91 unavailable cells;
none pass. Browser chat Stop is
not generated-output Stop, and a generated web preview served by a native host
is not browser-hosted source execution.

The report JSON format and Flutter viewer are unchanged. Historical reports and
observations remain immutable; earlier manifest hashes do not become current.
This correction adds no runtime capability or manual acceptance evidence, and
full F17 remains In progress. Existing actual browser refusal evidence is in
issue #293 and the PR #319 Plan observation. Run
`python3 -B tools/test_product_acceptance.py` to check scope validation,
legacy defaults, provenance refusal and freshness.


## Browser-only archive fixture scope — issue #293 extension

`archive-reopen/archive-browser` targets only web. Its referenced
`browser_archive_file_test.dart` declares `@TestOn('browser')` and uses
`dart:js_interop` to verify browser download behavior; this fixture is unavailable
on native targets. Native archive-records and archive-interaction remain eligible,
with missing evidence until supplied. This scope does not remove native archive
export/import support or establish a new acceptance pass.

The empty matrix contains120 cells:29 missing,91 unavailable,zero passes.
Excluded native archive-browser evidence rejects every saved status. Eligible web
evidence can pass only its own fixture cell; prior-manifest web evidence is stale.
Historical reports are retained unchanged. Full F17 remains In progress.

## Paired native Stop and command deadline — reused #283

The [paired observation](acceptance/2026-10-31-native-stop-deadline/observation.json)
records a fresh native pair on the retained isolated `584c89c4` candidate. It is
separate from the earlier Stop-only and deadline-only deliveries. The same new
candidate folder, approval, requirements/input snapshot, recorded sources,
tasks, SDK and limits bind both runs. The pinned lock and package configuration
also match; regenerated package-graph bytes differ and both exact resolution
digests are retained separately without an equivalence claim. A deterministic loopback fixture
provided the explicitly reviewed test seed; no model inference is asserted.

On the ready disposable deadline project, reopen Build and source review. Select
only the approved `test/generated_app_test.dart`, review the single five-minute
async test addition with its ten-minute Flutter test timeout, then prepare a new
candidate under a temporary parent. Grant confined-verification consent. After
resolve and analysis pass and the test starts, choose Stop; inspect saved test
exit -1 with cancellation true, timeout false and no build dispatch. Explicitly
verify that same candidate again. Let the test reach ASG's 180-second command
deadline; require timeout true, cancellation false, no build, no automatic repair
and no promotion. Retain both journals and compare exact linkage before submitting
combined evidence. Keep the last working source/output and ready pointer intact.
Serve that retained output and exercise add/check interaction. Quit, independently
confirm absence, reopen and inspect the ready build/current approval; compare the
board, approval, working record and full candidate journal after reopen. The UI
reopens the working baseline; prior failed candidate details are verified from the
retained durable journal, not a restored source-review session.

The supplied report records only the combined macOS manual cell. It does not infer
individual check passes, live-model health, current-main build support, criterion
verification or completion of F17. Source/bundle manifests remain the referenced
historical compiled identity, remeasured for this run; prior reports are unchanged.
Regenerate from the Flutter root with the collector command above, substituting
this directory's `identity.json` and `evidence.json`. Only `generatedAt` changes.


### Actual web report-viewer retry recovery (issue #255)

[Reproduction and limits](acceptance/2026-10-31-web-viewer/REPRODUCE.md) and [observations](acceptance/2026-10-31-web-viewer/observation.json) record real releaseweb inspection of historical/matching reports, six omitted checks, invalid replacement retention, Clear/reopen and controlled503→restored200 asset retry. This revealed and fixed a cached failed string-load Future. Runtime/build/report hashes and corrected screenshots are retained. Existing reports/statuses stay unchanged; no new collector cell, native launch, inference or fullF17/support claim.
