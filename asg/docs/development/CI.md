# Continuous integration

The CI workflow runs on pull requests to main, pushes to main and manual dispatch. It uses read-only repository permissions, disables persisted checkout credentials, pins action commits and cancels superseded runs. Flutter 3.47.6 matches the application SDK requirement and local verification environment.

The Flutter job enforces the committed dependency lockfile, Dart formatting, analysis, default tests, a dedicated Chrome IndexedDB migration/recovery test and a web release build, followed by actual independent Flutter project generation/analyze/test/build verification. The Python job runs strict product-acceptance manifest/evidence-report regressions, download-helper and HTTP/SSE fixtures using Python 3.12 plus bounded generation-command process fixtures, without installing inference packages or downloading model weights. Failures stop the affected job; both jobs must pass before reviewer merge.

The live Qwen integration test is deliberately skipped in default CI. It requires an explicitly configured local runtime and `--dart-define=ASG_REAL_INFERENCE=true`; a skipped test is not evidence of successful inference. CI does not verify Android, iOS, Linux, Windows or macOS builds. Run relevant platform checks locally when changing platform behavior. Swift preference migration checks require macOS.

Issue forms capture reproducible bugs or focused requirements, acceptance criteria and validation. The PR template records linked issues, actual test results and limitations. Follow root AGENTS.md for independent review and conditional merging.

The app under test is Flutter for Android, iOS, web, macOS, Windows and Linux. Linux CI hosts testing the generator do not establish Linux product support for macOS-only generation UI. Record results for each exact PR head; a new documentation commit also receives required checks and fresh review. Test totals can differ by host exclusions; report actual passed/skipped results rather than assuming a fixed count.
