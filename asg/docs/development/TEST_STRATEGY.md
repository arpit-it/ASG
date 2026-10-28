# Test strategy

ASG is a Flutter application targeting Android, iOS, web, macOS, Windows and Linux. Included platform runners do not establish tested device support. Managed MLX setup and the current independent Flutter web generator host are macOS-specific; other platforms retain supported app features and runtime connection controls.

Run from `asg/`: formatter, `flutter analyze`, `flutter test` and a relevant platform build. Unit/controller/widget tests cover MVC boundaries, guided creation/session races, streaming and absolute timeouts, save-only retries, durable interactions, requirements/dependency validation, exact Plan approval, task import/preview and Build provenance/progress. Failure tests must prove preservation of last-working state, no unauthorized host side effects, async overlap/disposal handling and readable narrow/enlarged-text UI.

Native database tests perform actual close/reopen, migration and corrupt-record preservation. Run `flutter test --platform chrome test/browser_storage_test.dart` for real IndexedDB; CI runs it explicitly. Native generation fixtures validate path/source/metadata/output boundaries, failure recovery and owned-process cleanup. CI also runs real independent Flutter project resolution, analysis, tests, web build and served-output verification; this does not invoke Qwen.

Live inference tests require the explicitly configured existing model and `--dart-define=ASG_REAL_INFERENCE=true`. Run them alone to avoid the runtime's single-worker limit. Historical MLX custom-edit/Plan/Review runs passed; endpoint availability must be checked for each live run. This documentation update performs no fresh inference. See [streaming commands](../setup/QWEN_STREAMING.md). Mocked/fixture and skipped tests cannot establish live model behavior.

Historical issue #50 validation (not current suite totals): formatter/analyzer, 200 default tests (four opt-in skips) and web build passed before the documentation-only audit. Final PR CI/reviewer evidence belongs in the requirements ledger and history. macOS debug, Android debug and web builds passed in earlier increments; device launches and iOS/Windows/Linux app builds are not established. Run applicable native checks when those integrations change. Manual picker, packaged-runtime setup and device acceptance remain separate from compile success.


F04 adds native candidate confinement probes (`python3 -B tools/test_candidate_confinement.py`), exact-working/approval/transaction-failure and narrow-screen controller/widget regressions, and actual database reopen of atomic working/previous pointers. CI runs portable profile/fail-closed tests; native Seatbelt probes and actual confined generated-project verification require macOS and are run locally. `test/candidate_real_test.dart` has separate opt-in ASG_REAL_GENERATION and ASG_REAL_INFERENCE flows; the latter must use the real existing local provider and complete confined checks, promotion, refreshed HTTP preview and durable reopen. Set ASG_BROWSER_REVIEW=true only for deliberate visible browser inspection; it holds the temporary preview for two minutes. Neither skipped tests nor deterministic fixtures count as fresh local-model acceptance.

## Current verification boundary

F04 reviewed candidate and F05 bounded automatic-repair real-model acceptance were delivered in PRs #93 and #103; `test/candidate_real_test.dart` and `test/automatic_repair_real_test.dart` retain opt-in coverage. These historical passes do not establish current endpoint availability. F06–F09 and F14 have subsequent regression/acceptance evidence in the requirements ledger. F10 report evidence remains distinct from criterion-specific product acceptance. See the sole [requirements queue](../REQUIREMENTS.md) for planned backend/host portability and real product verification; no broader platform support follows from fixtures or skipped tests.


## Importing F10 snapshot observations into F17 saved evidence

`tools/import_acceptance_provenance.py` joins one digest-only object emitted by
`ASG_F10_PROVENANCE` with a separately supplied collector identity. Extract only
the JSON object from the private test log, not the whole log or historical wrapper.
Use the identity schema in `tools/product_acceptance.py`; environment fields and
status are explicit caller attestations, not measurements or authentication.
The source revision, requirements digest and input digest must exactly match the
F10 snapshot. Generated-source, approval and saved-run digests plus the hash of
the complete provenance object are retained as bounded artifact references.

```sh
python3 -B tools/import_acceptance_provenance.py \
  --manifest docs/development/product_acceptance_manifest.json \
  --identity identity.json --evidence evidence.json \
  --provenance provenance.json --check model-proposal --target macos \
  --status skipped --observed-at 2026-10-28T07:00:00Z \
  --output imported-evidence.json
python3 -B tools/product_acceptance.py \
  --manifest docs/development/product_acceptance_manifest.json \
  --identity identity.json --evidence imported-evidence.json --output report.json
```

Start an empty evidence file with `{"schemaVersion":1,"records":[]}`. Use distinct
output paths; import refuses all input aliases and duplicate scenario/check/target
records. Existing evidence is preserved; a refreshed observation requires an
explicitly curated input evidence file. Supported mappings are reviewed-candidate
→ model-proposal or confined-checks, and bounded-repair → real-repair-rerun.
Each command imports exactly one observed check. Set passed only after separately
observing that specific check; a provenance line alone does not establish success.
No import runs tests, launches a model, checks live files or promotes any other
cell. The collector compares identity/manifest for freshness, and the app continues
to label reports saved evidence. This bridge does not complete the real native/web
manual baseline or establish device support. Never publish private logs, prompts,
model paths or credentials as input metadata.
