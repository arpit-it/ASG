# Repository workflow

Repository: https://github.com/arpit-it/ASG

Use issue-linked branches and reviewed pull requests. Preserve unrelated files and staging. The owner-authorized baseline publication for issue #1 was a one-time historical exception.

## Task selection and ownership

[Requirements](../REQUIREMENTS.md) is the sole task queue and current status authority. Resume active owned work first. Under the owner's 5 November 2026 authorization, up to two dependency-independent writers may work in distinct registered worktrees with nonoverlapping claimed paths. A dependent task waits for its prerequisite's verified merge. The [parallel development procedure](PARALLEL_DEVELOPMENT.md) defines claims, compact contracts, lease recovery, integration and metrics. Use one writer when a second safe task or sufficient host capacity is unavailable.

Create/reuse an issue before implementation; at most one necessary new issue per scheduled run. Describe an observable user outcome, allowed paths, dependency evidence, acceptance examples, representative failure cases and checks. Combine related behavior and necessary failure handling into a coherent increment. Do not split every method into a separate PR; immediate security/regression repairs may remain focused.

## Naming and communication

Use `<issue-number>-<short-description>` branch names without assistant/provider identification. Do not add such identification to PR titles/bodies. If a working identity is needed, use exactly "ASG is working". Do not announce routine branch creation. Historical names remain unchanged.

## Work cycle

1. Read AGENTS.md, coding standards, requirements and current history. Inspect local status, remote issues/PRs and existing owners before selecting work.
2. Inspect remote main through the connected GitHub plugin and safely synchronize local refs without replacing dirty work. Create an isolated registered worktree and issue-linked branch through the app's worktree tool when available.
3. Complete an execution contract and acquire its coordinator claim before editing. Never share a writer checkout, overlap a claimed path, take a third writer slot or assume an expired claim is abandoned. Keep tokens out of commits, logs and PRs.
4. Implement within scope. Use read-only research/test-design specialists where useful; retain a separate final reviewer. Stop and renegotiate before expanding scope or changing dependencies.
5. Run focused tests during editing and relevant regressions before publication. Review `git diff --check`, the full diff and explicit staged paths. Keep fixture, live model, host and build results distinct.
6. The integration owner acquires the exclusive integration slot before publishing or starting final CI. Other writers may continue independent implementation but cannot integrate/merge. An integration owner actively editing occupies one of the two writer slots. Bring current main into the candidate without losing changes, commit related paths and verify final source identity.
7. Publish through the connected GitHub plugin, verify remote contents match the tested tree, and open/update a linked PR. Include the contract, resulting behavior, exact tested revision, checks, limitations and recovery implications. Attach the PR to the current task where available; use draft state when incomplete.
8. Run every required check on the final revision. An independent reviewer inspects that exact diff, acceptance coverage and actual check results. Resolve findings, retest affected behavior and request fresh review if head/base changes. Record observations and run coordinator `ready`; this never replaces GitHub checks/review.
9. The independent reviewer merges through the protected PR only when required checks pass and conversations are resolved. Verify remote merge/tree/main state and issue closure. Record verified outcome and merge evidence; release integration and claim. The integration owner reconciles requirements/history in the next appropriate reviewed increment when the merge necessarily postdates its own documents.
10. Synchronize local main only when safe. Preserve dirty checkouts. Archive completed managed worktrees through the app tool; preserve abandoned/recoverable work rather than resetting it.

All GitHub reads/writes, publication and protected merges use the connected GitHub plugin. Do not substitute terminal push, authentication setup or browser publication. Local Git is for inspection, local commits and safe synchronization. Never force-push shared history, weaken branch protections or execute unrelated hooks/submodules automatically.

## Validation and integration

Focused checks give early feedback; they do not replace required CI. Existing required Flutter checks/web build and Python fixtures remain mandatory. Documentation-only local edits need not rerun unrelated builds, but the final PR still satisfies required branch checks. Reuse prior evidence only for unchanged inputs where an explicit verification policy permits it. Changed source, input, adapter, model or host invalidates affected evidence. Skipped live inference does not verify a model.

Keep integration ownership through publication/check/review/merge so cooperative local writers cannot race main. If another actor changes main, safely update the candidate and repeat affected validation, independent final review and required CI. The local tool cannot prevent another machine, separate clone or external contributor from changing remote main; branch protection remains authoritative.

## Historical foundation issues

Completed provenance, not a task queue: #1 baseline publication; #2 CI/templates; #3 independently generated Flutter projects; #4 transactional storage. Current delivery evidence lives in the canonical requirements ledger, not stale snapshots here.
