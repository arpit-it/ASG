# Automated Software Generator project conventions

The Flutter application root is `asg/`. Run Flutter commands there.

Read and follow [the project coding standards](asg/docs/development/CODING_STANDARDS.md) before working on this repository. This is the canonical instruction document for Flutter style, MVC boundaries, async work, storage, UI, testing, and completion checks. Direct user instructions take precedence; preserve unrelated changes.

Use MVC for new application features and files:
- `lib/models/`: typed domain data and pure validation/serialization. No Flutter widgets, HTTP clients, or storage plugins.
- `lib/views/`: screens and reusable UI. Keep layout, rendering, navigation, and text/form controller lifecycle here. Delegate application actions to controllers; do not send HTTP requests, serialize stored records, or use preferences directly.
- `lib/controllers/`: application state, validation/workflow coordination, loading/error state, and controller actions. No widgets, BuildContext, dialogs, or navigation. Dispose listeners and cancel owned work.
- `lib/services/`: storage, local model transport, folder picker, execution policy, and other platform/external integrations. Inject services/providers into controllers for deterministic tests.
- `lib/main.dart`: bootstrap and top-level error presentation.

Use one controller per feature and split screens into focused view files. Avoid recreating a single large UI file. Keep business rules out of widget callbacks. Preserve existing preference keys and JSON formats unless an explicit migration is implemented.

The fixed Flutter web generator uses the same MVC separation; see asg/docs/architecture/GENERATION.md for actual supported behavior and safety limits. Do not describe this initial template slice as arbitrary model source synthesis. Other future framework adapters should map these responsibilities idiomatically.

Validate with `flutter analyze`, `flutter test`, and a relevant platform build. Architecture tests in `test/architecture_test.dart` guard core import boundaries. Add controller tests for error handling, persistence ordering, and async disposal when changing workflows.

## GitHub issues, branches and pull requests

Repository: `https://github.com/arpit-it/ASG.git` (`origin`). The user authorized publishing the reviewed existing baseline directly to `main` once, tracked by issue #1. After that initial publication, use the following workflow for every new implementation, bug fix or scheduled development increment:

1. Read or create a GitHub issue before implementation. Record the problem, scope, acceptance criteria and validation plan. Reuse an existing issue instead of creating duplicates.
2. Inspect `git status`, staged changes, branch and remote state. Run `git fetch origin` and inspect divergence before integrating updates. Preserve unrelated edits; do not discard, reset, auto-stash or stage someone else's work.
3. Create one focused branch per issue, named `codex/<issue-number>-<short-description>`, from current `origin/main`. Use an isolated worktree if the current checkout cannot safely accommodate the change. Do not implement subsequent work directly on `main`.
4. Implement a coherent increment following MVC and CODING_STANDARDS.md. Add relevant regression tests and update project memory/progress. Keep model weights, virtual environments, credentials, build output and local IDE caches out of commits.
5. Review `git diff` and `git diff --cached`, run format/analyze/tests and appropriate builds, then commit only related paths with a descriptive conventional commit message. Link the issue in the commit or PR.
6. Push the feature branch with an upstream (`git push -u origin <branch>`). Open a PR targeting `main`, with a concrete behavior summary, linked issue (`Closes #<number>` when complete), tests and material limitations. Use a draft PR if incomplete. Attach created PRs to the Codex task when the app's PR attachment tool is available.
7. Keep the issue and PR updated. Merge through the PR, following required checks/review. The user now authorizes an independent reviewer agent to merge PRs after approving the final revision and confirming required checks pass. The implementing agent must not self-approve or bypass that independent review. After a merge, fetch and fast-forward local `main` only when safe; verify the remote result before claiming completion.

The user's authorization covers in-scope issue creation, branch creation, commits, feature-branch pushes and PR creation; do not repeatedly request permission for those routine steps. Never force-push shared branches, rewrite published history, bypass branch protection, or push unrelated files. Rebase only unshared local work unless otherwise authorized; use `--force-with-lease` solely when a necessary private-branch rewrite has been explicitly agreed. Never use an unconditional force push.

These rules also apply to the 15 minute automation. Read `asg/docs/REQUIREMENTS.md`, `asg/docs/history/AGENT_MEMORY.md` and `asg/docs/history/PROGRESS.md`, select the next open issue, and use its dedicated branch/PR. Publishing source is not a claim that a production application has been deployed; obtain a concrete release/deployment target before provisioning or publishing external services.


## Scheduled issue selection and independent review

At each 15 minute run, inspect current app status and open issues/PRs. Finish in-progress work first. Reuse an existing issue whenever suitable; create at most one necessary, narrowly scoped new issue per run only when no existing issue covers a real gap. Do not invent issues or expand a speculative backlog. Complete implementation, test, fix discovered defects, and retest before moving on. Keep genuinely blocked work open with clear evidence rather than pretending it is finished.

The user explicitly requests and authorizes reviewer-agent delegation. After opening a PR, spawn an independent reviewer agent to inspect that PR's exact final diff, acceptance coverage and real CI/test results. The implementer must resolve blocking findings, retest affected behavior and request re-review if the diff changes. The reviewer is authorized to merge into main only after approving the final revision and confirming all required checks pass. Never self-approve, bypass protection or merge a failing PR. Verify the remote merge and issue closure; update memory and safely fast-forward the local main checkout.

## Repository safeguards

Main is protected with required PRs, the Flutter checks and web build / Python runtime fixtures checks from GitHub Actions, up-to-date branches and resolved conversations. Admins cannot bypass; force pushes/deletion are off. Do not weaken controls to merge. All external fork workflows need approval: inspect submitted code and workflow/dependency changes before approving execution. Never approve unknown code automatically. CODEOWNERS requests owner review; the reviewer agent shares the owner's GitHub identity, so its independent verdict is not a second GitHub approver. Required GitHub approval count remains zero until another trusted account exists.

Preserve read-only workflow permissions and disabled Actions PR-approval permission. The Actions allowlist permits owner actions, GitHub-created actions and subosito/flutter-action@1a449444c387b1966244ae4d4f8c696479add0b2; coordinate reviewed workflow upgrades with the allowlist. Keep visibility unchanged unless the owner explicitly requests a change. See CONTRIBUTING.md and SECURITY.md.


## Canonical documentation and scheduled task queue

The sole requirements and task file is `asg/docs/REQUIREMENTS.md`. Read it on every 15 minute run, together with `asg/docs/history/AGENT_MEMORY.md` and `asg/docs/history/PROGRESS.md`. Follow its new-task, deduplication, dependency and completion rules. Add justified new tasks there with stable IDs and acceptance criteria; do not maintain another backlog in roadmap or memory files. Finish active work and verify its merge into main before selecting the next task. Check Done only after acceptance, relevant checks, independent review and verified remote merge; record PR and merge SHA. Supporting documentation is indexed in `asg/docs/README.md`.
