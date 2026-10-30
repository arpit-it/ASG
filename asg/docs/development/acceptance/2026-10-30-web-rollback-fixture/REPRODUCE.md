# Browser rollback record fixtures — F17 / issue #253

At source `98aeb6142fe0bd649f4ea383534100272aaa3401`, run from Flutter root:

```sh
flutter test --platform chrome test/browser_build_history_test.dart --reporter expanded
python3 -B tools/test_product_acceptance.py
python3 tools/product_acceptance.py --manifest docs/development/product_acceptance_manifest.json --identity docs/development/acceptance/2026-10-30-web-rollback-fixture/identity.json --evidence docs/development/acceptance/2026-10-30-web-rollback-fixture/evidence.json --output /tmp/browser-rollback-report.json
```

Actual Chrome 156.0.8078.74: two passed, zero skips, exit 0; retained log
reports no teardown fallback. Flutter 3.47.6 / Dart 3.13.5 on macOS 27.0.1
arm64. Formatter/analyzer clean; 882 default tests passed, eight opt-in skips;
27 Python collector fixtures passed. Synthetic ready records contain placeholder
artifact digests, never actual verified output. Initial incomplete fixture was
rejected by production validation and corrected before the successful run.

The successful-selection branch retains the exact previous record and unchanged
journal across IndexedDB close/reopen. Both branches refuse failed/forged
selection and preserve unrelated records and corrupt raw history. A second
storage session changes durable data behind a stale cache; compare-and-set must
refuse both updates. Authorization refusal also preserves both records.

This is one web history-rollback/rollback-records fixture cell among 120 cells.
It does not exercise the native rollback controller, artifact validation, served
preview or manual selection, and does not enable native generation in browsers.
No model, application build/launch or full F17 acceptance is claimed. Multiple
synthetic project snapshots have no single F10 requirement/input identity;
requirement/input/model use SHA256 of UTF8 unavailable. Source manifest hashes
tracked runtime/tests/tools/package inputs at the exact published source tree.
Config/device hashes use canonical JSON; artifact digests use exact file bytes.
Regeneration differs only in generatedAt. Mutating source, requirement, input,
configuration, model or device independently removes the saved pass. Historical
observations retain their original manifest identities. Raw logs remain private.
