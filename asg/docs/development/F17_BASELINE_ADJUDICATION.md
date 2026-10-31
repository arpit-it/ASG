# Initial macOS/web baseline adjudication

31 October 2026; F17; [issue #253](https://github.com/arpit-it/ASG/issues/253).
Publication base: `2c61072c2902c788e21fdd5a4a4d04ab4fee36ed`.
Status: Initial baseline accepted after independent final-revision approval5722192777/finalgate5722205595, required CI41189201083 and reviewer protected merge [PR #327](https://github.com/arpit-it/ASG/pull/327) as `1a4251c992ce32921880fdc5395605ac189f79e3` at2026-10-31T09:38:29Z. Later platform/host coverage remains explicitly unavailable. The remaining future-tense gate text records the pre-merge proposal; all gates were subsequently verified as recorded in the requirements ledger.

The initial baseline is ready for an acceptance decision using the actual
separate workflow observations below. This is a review of previously observed
behavior and its source changes, not a new execution or combined passing report.
F17 remains unchecked until that decision passes the normal delivery gates.

## Acceptance coverage

Paths in the table are relative to [the observation directory](acceptance/).
Each directory's `identity.json`, `evidence.json` and `report.json` retain their
original per-result revision, requirement/input/configuration/model/device
identities, UTC, status and artifact digests. The [inventory](acceptance_inventory.json)
links all 29 configured cells to 21 separate reports; it is an index, not proof
that those observations are current. Read each observation and its limitations.

| Initial acceptance clause | Actual evidence | Reviewed delivery |
| --- | --- | --- |
| Native create, edit, reopen | [native-reopen observation](acceptance/2026-10-30-native-reopen-matrix/observation.json): checked prototype and edited board/task retained after Quit/relaunch; original creation separately recorded | PR #296 / earlier #274 |
| Browser create, edit, reopen | [web-reopen observation](acceptance/2026-10-29-web-reopen-matrix/observation.json): wizard, linked requirement/task, checked prototype, acknowledged revision edit and two reloads | PR #295 |
| Durable records and rejected writes | [native fixtures](acceptance/2026-10-30-native-fixture-baseline/), [browser durable fixtures](acceptance/2026-10-30-web-durable-fixture/): exact edited project/chat/board reopen and failed-write preservation; fixtures remain distinct from manual results | PR #311 / #316 |
| Explicit Plan approval and stale refusal | [native Plan](acceptance/2026-10-30-native-plan-matrix/), [actual browser Plan](acceptance/2026-10-31-web-plan-matrix/): approval/reopen, requirement change, outdated approval; native gate refusal and working-output preservation | PR #299 / #319 |
| Real proposal, reviewed diff, confined checks, promotion, served behavior | [native candidate observation](acceptance/2026-10-30-native-fingerprint-candidate/observation.json): actual MLX proposal at compiled584c89c; full one-line diff; four zero exits; explicit promotion; actual served item add/check and restart | PR #302 |
| Failed-check repair and rerun | [real repair](acceptance/2026-10-30-real-repair-matrix/), [native repair interaction](acceptance/2026-10-30-native-repair-interaction/): deterministic undefined call causes analyzer failure; real MLX correction; four passing checks; explicit promotion; served add/check, preserved baseline and restart | PR #308 / #309 |
| Stop, full retry and preservation | [native Stop/retry](acceptance/2026-10-30-native-stop-retry/): actual Stop during analyze, saved cancellation/downstream refusal, explicit successful full retry and served interaction | PR #305 |
| Deadline and paired cancellation distinction | [command deadline](acceptance/2026-10-30-native-command-deadline/), [deadline reopen](acceptance/2026-10-30-native-deadline-reopen/), [paired Stop/deadline](acceptance/2026-10-31-native-stop-deadline/): actual bounded test deadline, separate cancelled/timedOut flags on same candidate, unchanged working files, served add/check and restart | PR #307 / #317 / #322 |
| Selected rollback | [native selected rollback](acceptance/2026-10-30-native-rollback-matrix/): explicit retained build selection, prior work preserved, served add/check and restart; browser record fixtures do not imply browser host rollback | PR #306 / browser records #315 |
| Archive restore and reopen | [native archive](acceptance/2026-10-30-native-archive-matrix/), [web archive](acceptance/2026-10-30-web-archive-matrix/): separate restore, original retained, exact board/prototype reopen, corrupt/incompatible refusal; fixture observations remain separate | PR #297 / #310 / #312 / #313 |
| Actual platform build and launch | [native launch](acceptance/2026-10-31-native-launch-matrix/), [web build/launch](acceptance/2026-10-29-web-reopen-matrix/): unique native bundle/empty home and actual Chrome application | PR #318 / #295 |
| Honest saved evidence and missing coverage UI | [web viewer](acceptance/2026-10-31-web-viewer/observation.json), [native viewer recovery](acceptance/2026-10-31-native-viewer/recovery-verified.json): historical/omitted checks, invalid replacement retention, Clear/reopen, failed asset Retry; synthetic inputs establish viewer behavior only | PR #323 / #324 / #325 |

The reports include fixture/build/launch/inference/generated/manual kinds
separately. Generic green checks do not establish free-form acceptance prose.
F10 requirement/input bindings remain scoped to their actual project snapshots;
no common requirement digest or run identity is invented for unrelated projects.
Multi-project fixtures use explicit unavailable identities as documented.

## Source change assessment

Inspection used local Git object comparisons, not inference from a matching
manifest digest. Exact current publication application content is unchanged from
PR #325; PR #326 added only inventory tooling, CI invocation and documentation.

From native workflow commit `584c89c4cc98522b75b65d53ecbd52c5e21d6859`
to the publication base, application changes are restricted to:

- `lib/controllers/product_acceptance_controller.dart` and
  `lib/views/product_acceptance_screen.dart`;
- new `lib/models/product_acceptance_manifest.dart` and
  `lib/services/product_acceptance_manifest_service.dart`;
- one `pubspec.yaml` bundled manifest asset entry.

Generation, approval, storage, history, archive, repair, native runners,
dependency lock and Qwen server code are unchanged across that range. These
viewer changes have actual later web/native interaction evidence above,
including the discovered cached-asset failure and verified recovery. They do not
change the underlying historical project workflows.

Earlier native persistence/Plan/archive at `422363fc04db6a20b6c515c25dc71f4becaafff6`
and browser persistence at `87d8cb4b7bdda9ad49327f00124731e29b7c55a3`
also precede proposal snapshot/token corrections. The additional application
change is `source_edit_proposer.dart`; Qwen's output cap increases from2048
to4096. The proposer obtains/validates the beforeSha256 snapshot and requests
4096 tokens. Normal chat/Plan callers still request at most2048. These changes
therefore affect proposal/repair workflows, which the later compiled584c89c
candidate and repair observations exercise; they do not alter no-inference
persistence/archive paths or the Plan request budget. Source changes are reviewed
semantically here; file hashes alone do not establish unaffected behavior.

Reproduce the partition from repository root:

```sh
git diff 584c89c4cc98522b75b65d53ecbd52c5e21d6859 2c61072c2902c788e21fdd5a4a4d04ab4fee36ed -- asg/lib asg/pubspec.yaml asg/pubspec.lock asg/tools/qwen_server.py asg/macos asg/web
git diff 422363fc04db6a20b6c515c25dc71f4becaafff6 584c89c4cc98522b75b65d53ecbd52c5e21d6859 -- asg/lib asg/tools/qwen_server.py
```

## Linked provenance and limitations

Eight reports lack an adjacent source-manifest file. That inventory flag is not
proof of missing external provenance. Native Stop/retry, selected rollback,
repair interaction and paired Stop/deadline configuration records explicitly
reference the fingerprint-candidate directory's 300-file source manifest
`e6e920052caf6095e78cd54d146f623d09535f9126b7a468eeb654685b1660b9`
and 43-file bundle manifest
`fd7a3dbdd9469960b2b18f291fd32f2ddea2b45c5e241cdfe81c04da45b81be0`.
Preserve these links; do not copy or relabel their contents as a new observation.
Earlier native reopen records exact422363fc and its 504-source comparison;
Plan/archive manifests at that same source provide additional inspectable
source context. Historical compiler/bundle overrides isolate app storage;
they do not prove byte-identical production bundles.

The independently observed results use Flutter3.47.6, their recorded Dart/Python
versions and existing local Qwen3.5-9B MLX profiles. Some older browser numeric
versions are unavailable. No browser-version compatibility, physical-device
support, present model readiness or new live inference is asserted here. A fresh
computer-use inventory in this run showed stable ASG stopped and no ASG browser
test tab; this is cleanup state, not an application launch result.

Native Android/iOS/Windows/Linux and physical devices remain unverified and
explicitly unavailable in this initial matrix. Browser execution/promotion,
repair, Stop/deadline and selected artifact rollback remain unavailable where
the native generation host is unsupported; browser storage tests do not enable
them. Managed MLX/generation-host claims remain limited to the actually observed
macOS workflows. Later platform/backend/adapter milestones require their own
actual tests before support advertising.

The initial baseline decision does not create an aggregate currentPass, upgrade
stale reports, authenticate caller observations, establish all application
features on every platform, or certify arbitrary generated software. Rerun
**affected** scenarios after relevant source/toolchain/model/configuration
changes. Do not rerun unchanged workflows merely to rewrite manifest metadata.

## Validation and delivery gate

At publication base: 32 collector tests and nine inventory tests passed;
regenerated inventory is byte-identical to the checked-in inventory. All29
configured cells retain historical references with no promoted status. Existing
report/evidence/identity/observation artifacts remain unchanged. This increment
changes documentation only; no new app build, native workflow, inference or
model download was performed.

Independent exact-final review must inspect the table's actual artifacts and
source partition, acceptance coverage, unavailable cells and actual required CI.
If it finds a missing acceptance clause, F17 stays In progress and the clause
must be completed. Only approved final revision, passing required checks and
verified protected merge permit marking the initial F17 task Done. Subsequent
platform expansion remains separately gated by F15/F16/F11 requirements.
