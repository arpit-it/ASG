# Chrome Plan approval storage fixtures — F17 / issue #287

Run from the Flutter root at source `f3c5d9b1bf0c0a162659d7f583f0f8862f9feef8`:

```sh
flutter test --platform chrome test/browser_storage_test.dart --reporter expanded
python3 -B tools/test_product_acceptance.py
python3 -B tools/product_acceptance.py --manifest docs/development/product_acceptance_manifest.json --identity docs/development/acceptance/2026-10-30-web-plan-fixture/identity.json --evidence docs/development/acceptance/2026-10-30-web-plan-fixture/evidence.json --output /tmp/web-plan-report.json
```

Actual Chrome 156.0.8078.74: four passed, zero skips, exit 0. Three
new cases exercise requirements, prototype revision and latest draft changes
against the real IndexedDB-backed store across close/reopen. Approval validity
uses the execution boundary, rather than comparing raw JSON alone. Every case
also proves fresh approval, durable withdrawal and corrupt evidence refusal
without replacing the raw record. The original migration test still passes.
Flutter 3.47.6 / Dart 3.13.5; analyzer and formatter clean, 882 default tests
passed with eight opt-in skips; 27 Python collector fixtures passed.

Only one web fixture cell is submitted among 120 report cells. No manual UI,
application build/launch, live inference, generated output or full F17 claim.
Multiple fixture snapshots have no single F10 identity; requirement/input/model
hash the explicit UTF8 unavailable sentinel. Configuration/device/observation
artifacts hash exact file bytes. Source manifest hashes tracked lib/test/tools
and package inputs; all match the published source tree. Six independent
source/requirement/input/configuration/model/device identity mutations remove
the saved pass. Prior observations retain their original manifest identities;
adding this test reference does not retroactively certify their freshness.
Raw test logs remain local. Retained Chrome log reports no teardown fallback.
