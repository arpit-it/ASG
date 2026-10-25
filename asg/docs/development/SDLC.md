# Development lifecycle

ASG is a Flutter application targeting Android, iOS, web, macOS, Windows and Linux. Included platform runners do not establish tested device support. Managed MLX setup and the current independent Flutter web generator host are macOS-specific; other platforms retain supported app features and runtime connection controls.

Discovery → requirements → feasibility → architecture → design → implementation → testing → independent review → user acceptance → release → maintenance. Each increment states bounded behavior and actual verification; a build or PR merge is not a packaged release/deployment.

Use [Requirements](../REQUIREMENTS.md) as the only task queue. Reconcile active work first, search for duplicates, select by dependency/priority and create at most one narrowly justified issue per automation run. Preserve unrelated edits and use a dedicated issue branch/PR. Test, fix and retest; independent final-revision approval and required CI precede reviewer merge. Verify origin/main and issue closure before Done; record exact tested revision, review, checks and merge evidence. The 15-minute schedule and notification preference remain unchanged. See [Git workflow](GIT_WORKFLOW.md).
