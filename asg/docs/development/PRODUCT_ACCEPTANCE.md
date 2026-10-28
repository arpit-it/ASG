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
