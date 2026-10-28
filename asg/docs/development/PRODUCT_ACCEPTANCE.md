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
1 MiB. This is a supplied-report reader, not an independent authenticity, manifest
completeness or live-freshness check. Omitted scenarios are not assessed. Saved
passes do not establish current support or replace the pending real baseline.


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
