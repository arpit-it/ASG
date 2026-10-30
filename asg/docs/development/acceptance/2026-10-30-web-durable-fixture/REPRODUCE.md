# Browser durable-records fixture — F17 / issue #253

At source `bfcc8b2b463cb9334cf06cff3c3d57c96373ffdf`, from Flutter root:

```sh
flutter test --platform chrome test/browser_storage_test.dart --reporter expanded
python3 -B tools/test_product_acceptance.py
python3 tools/product_acceptance.py --manifest docs/development/product_acceptance_manifest.json --identity docs/development/acceptance/2026-10-30-web-durable-fixture/identity.json --evidence docs/development/acceptance/2026-10-30-web-durable-fixture/evidence.json --output /tmp/browser-durable-report.json
```

Actual Chrome 156.0.8078.74: five passed, zero skips, exit 0; successful
retained log reports no teardown fallback. Flutter 3.47.6 / Dart 3.13.5 on
macOS 27.0.1 arm64. Formatter257 unchanged, analyzer clean,882 default tests
passed/eight opt-in skips;27 Python collector fixtures passed. One new test
covers edited project/conversation/requirements and unrelated records across two
IndexedDB close/reopens, malformed writes and transaction aborts. Raw durable
project/chat values are checked after each aborted transaction. Owned database
is closed/deleted by fixture teardown. Other four tests retain prior coverage.

Only one web create-reopen/durable-records fixture cell among120 is submitted.
No application launch/build, manual UI/restart, model, generated output or full
F17 claim. Multi-project fixture has no single F10 requirement/input identity;
requirement/input/model use SHA256 of UTF8 unavailable. Source manifest lists
281 tracked source/test/tool/package/browser hashes at the published
source tree. Config/device use collector canonical JSON; artifacts hash exact
file bytes. Regeneration changes only generatedAt; source, requirement, input,
configuration, model or device mutation independently stales the saved cell.
Prior observations retain historical manifest identities; never relabel them.
Raw test logs remain private.
