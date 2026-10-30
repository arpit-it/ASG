# Web portable archive record fixture — F17 / issue #253

Run from the Flutter root at source `0164df10a297c32b44421b863fe3294e10eff95a` using Flutter3.47.6 / Dart3.13.5 and actual installed Chrome156.0.8078.74:

```sh
flutter test --platform chrome test/portable_project_archive_test.dart --reporter expanded
python3 -B tools/test_product_acceptance.py
python3 -B tools/product_acceptance.py --manifest docs/development/product_acceptance_manifest.json --identity docs/development/acceptance/2026-10-30-web-record-fixture/identity.json --evidence docs/development/acceptance/2026-10-30-web-record-fixture/evidence.json --output /tmp/web-record-report.json
```

Actual Chrome:13 passed, zero skips, process exit0. Python:27 passed, exit0.
The retained browser log reports no cleanup fallback. These are archive model
serialization and validation fixtures; no file picker, application launch,
real database persistence, manual import/restart or model inference is inferred.
The prior archive-browser download and manual observations remain separate.

The source manifest hashes tracked lib/test/tools and package configuration;
documentation changes alone do not alter these execution inputs. Configuration,
device and observation artifacts use SHA256 of the exact formatted file bytes.
No single F10 requirement/input snapshot exists; their hashes and the model hash
use the explicit UTF8 `unavailable` sentinel. Runtime version means model runtime.

The120-cell saved report contains exactly one web archive-records pass. Six
separate source/requirement/input/configuration/model/device identity mutations
make that record stale and remove all passes. Regeneration differs only in
`generatedAt`. No aggregate support or full F17 completion is claimed. Local raw
logs stay private; only bounded sanitized outcomes and digests are published.
