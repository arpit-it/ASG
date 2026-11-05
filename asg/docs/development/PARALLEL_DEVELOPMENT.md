# Coordinated parallel development

The owner authorized this workflow on 5 November 2026 under issue #510. It supersedes older single-active-issue instructions only for coordinated, dependency-independent work. [Requirements](../REQUIREMENTS.md) remains the sole task queue and completion authority. This document defines how to execute work; examples are not queued features.

## Roles and limits

| Role | Responsibility | Write authority |
| --- | --- | --- |
| Coordinator | Select ready work, scope tracks, manage capacity and integration order | Read-only while two writer slots are occupied |
| Writer, maximum two | Implement and test one claimed outcome in its own registered worktree | Only the literal file/directory prefixes in its contract |
| Research/test-design specialist | Map code, check documentation, identify edge cases or propose independent scenarios | Read-only; implementation changes require a writer slot |
| Integration owner | Combine final handoffs, edit shared ledgers, publish, serialize checks/review/merge | Counts as a writer while editing; one exclusive integration slot |
| Independent reviewer | Inspect exact final diff, acceptance and real checks, then merge if all gates pass | No implementation edits; findings return to a writer |

Two writers must have disjoint paths and no unmet dependency on each other's unmerged work. Each gets a separate registered Git worktree and issue-linked branch. Two tracks under one parent issue may produce a single coherent PR; do not split tiny methods merely to increase PR counts. For example, a data-import outcome may include parsing, validation, error display and restart tests in one increment. An unrelated document recipe may proceed concurrently only when it does not depend on that unfinished import.

If a writer discovers a shared-file change is needed, stop that portion and hand it to the integration owner or release/reclaim a revised scope before editing. Only the integration owner edits shared requirements/history, acceptance manifests, dependency lockfiles and cross-cutting workflow policy. Writers send scoped patches and evidence; they do not copy an old entire ledger over a newer one.

## Compact execution contract

Copy [the example contract](execution_contract.example.json) to a private temporary file and replace the example fields. Include:

- Stable issue/track `task` and canonical `requirement` ID.
- One observable `outcome`, not an implementation activity.
- `dependencies` with task IDs and concrete prerequisite merge evidence; an empty list is explicit independence.
- Literal repository-relative `scope` file or directory prefixes; no globs, parent traversal or broad catch-all scope.
- Testable `acceptance` examples, representative `failure_cases` and layered `validation`.

A contract is a local execution record, not a second backlog. Its dependency evidence is supplied by the operator; inspect the actual prerequisite merge through the GitHub plugin before claiming. Missing evidence blocks dependent work even if a model says it is ready. Changes to scope or requirements need a revised contract and renewed ownership before effects.

For concurrent tracks, agree on the boundary first: typed interface, ownership, tests and handoff identity. Begin with one implementer plus research/test design if a clean separation is unavailable. Use deeper reasoning for architecture, async races, security and final review; use lighter effort for narrow discovery or mechanical edits, then verify actual output. More agents or a higher setting do not prove correctness.

## Claim before editing

The stdlib Python coordinator uses SQLite transactions in the repository's Git common directory, so registered worktrees on this host share ownership. Run commands from the repository root, or pass the root with `--repo`. Status/report output is local operational evidence; keep it outside project artifacts and public logs.

```sh
python3 asg/tools/development_coordinator.py --repo "$ASG_WORKTREE" status
python3 asg/tools/development_coordinator.py --repo "$ASG_WORKTREE" claim --contract "$ASG_CONTRACT" --owner "$ASG_RUN_ID" --lease-seconds 900
```

Claim a clean registered worktree before making edits. Keep the returned token private in the owning process/session and refer to it below as `ASG_TASK_TOKEN`; do not paste it into PRs, terminal transcripts, committed contracts or shared logs. Do not reuse another writer's token. The tool rejects the same task, overlapping paths, a third writer or an already claimed checkout within one Git common directory. Commands in another repository cannot operate these claims; a separate clone has a separate database and does not share these locks. A rejected claim means wait or choose a genuinely independent ready task; using a separate clone to evade the limit is prohibited.

Renew before expiry while work is active:

```sh
python3 asg/tools/development_coordinator.py --repo "$ASG_WORKTREE" renew --task "$ASG_TASK" --token "$ASG_TASK_TOKEN" --lease-seconds 900
```

The first installation of the coordinator necessarily predates its own claim command. For issue #510 only, the coordinator explicitly assigned the two isolated writer scopes before implementation; this bootstrap does not authorize future unclaimed writing.

## Shared host resources

The two-writer limit is a ceiling, not a target. Keep the existing single-worker local model exclusive: the integration owner assigns one live inference test at a time and records the current owner in the handoff/issue before launch. Do not start a second live request while another writer owns the runtime; a free writer slot does not establish a free inference slot. Release resource ownership only after the owned request/process settles or its uncertain state is reconciled.

Apply the same rule to native build output, preview ports, mutable caches and shared artifact folders. Use distinct temporary directories/ports for independent fixtures and bound parallelism to measured memory/CPU capacity. The local coordinator does not implement a model server or OS resource scheduler; these assignments remain an explicit operational responsibility. A build is not proof of real device behavior, and a fixture is not a live inference pass.

## Layered validation and handoff

1. During editing, run focused regression tests that exercise actual changed behavior, especially representative failures. Research/test designers may prepare scenarios independently.
2. Before handoff, run relevant broader tests and required local format/analyze/build checks. Stop writing and send owned paths, tested head/tree, actual commands/results, failures/fixes, open limits and resource state to the integration owner.
3. The integration owner acquires exclusive integration before publication/final CI, reconciles current remote main and integrates handoffs without losing work. If editing, it occupies an available writer slot; it cannot become a third concurrent writer.
4. Run all existing required CI checks against the final candidate. The reviewer independently examines that exact diff, criterion coverage and actual results. A changed candidate or base needs new matching evidence and fresh review.
5. The independent reviewer performs the protected merge, verifies remote result/issue closure and returns evidence. Record completion only after that verification.

Reuse unchanged evidence only when an explicit verification policy permits it. Focused checks never substitute for required CI. Keep deterministic fixtures, skipped/live model tests, manual observations, native launches and platform builds separate. Do not shorten the feedback loop by weakening branch protection, removing tests or accepting a skipped real-host requirement.

## Serialized integration and revision evidence

The integration slot coordinates cooperative local writers while CI runs. Set `ASG_HEAD` to the exact committed worktree HEAD and `ASG_BASE` to the current main revision after remote verification and safe local ref synchronization.

```sh
python3 asg/tools/development_coordinator.py --repo "$ASG_WORKTREE" integrate --task "$ASG_TASK" --token "$ASG_TASK_TOKEN" --head "$ASG_HEAD" --base "$ASG_BASE"
```

Hold and renew ownership through publication, checks, review and merge. Every GitHub operation uses the connected plugin. Publish only tested in-scope content and verify the remote tree. Record actual observation references; do not label a pending CI run successful:

```sh
python3 asg/tools/development_coordinator.py --repo "$ASG_WORKTREE" record --task "$ASG_TASK" --token "$ASG_TASK_TOKEN" --kind ci_started --head "$ASG_HEAD" --base "$ASG_BASE" --actor "$ASG_RUN_ID" --evidence "$ASG_CI_URL"
python3 asg/tools/development_coordinator.py --repo "$ASG_WORKTREE" record --task "$ASG_TASK" --token "$ASG_TASK_TOKEN" --kind ci_finished --head "$ASG_HEAD" --base "$ASG_BASE" --actor "$ASG_RUN_ID" --evidence "$ASG_CI_URL"
python3 asg/tools/development_coordinator.py --repo "$ASG_WORKTREE" record --task "$ASG_TASK" --token "$ASG_TASK_TOKEN" --kind checks_passed --head "$ASG_HEAD" --base "$ASG_BASE" --actor "$ASG_RUN_ID" --evidence "$ASG_CI_URL"
python3 asg/tools/development_coordinator.py --repo "$ASG_WORKTREE" record --task "$ASG_TASK" --token "$ASG_TASK_TOKEN" --kind review_approved --head "$ASG_HEAD" --base "$ASG_BASE" --actor "$ASG_REVIEWER_ID" --evidence "$ASG_REVIEW_URL"
python3 asg/tools/development_coordinator.py --repo "$ASG_WORKTREE" ready --task "$ASG_TASK" --token "$ASG_TASK_TOKEN" --head "$ASG_HEAD" --base "$ASG_BASE"
```

Use a reviewer actor different from the implementation owner, with real independent reviewer evidence. Actor names are operator assertions, not separate authenticated GitHub identities. The `ready` gate checks local revision/ownership and matching observations; it neither queries GitHub nor executes a merge. Required remote checks, resolved conversations, fresh reviewer approval and branch protection remain authoritative.

If main changes externally, preserve work, finish/abandon the old integration attempt safely, integrate the new base and reacquire with the new exact identity. Repeat relevant checks, required final CI and independent review. A local integration lock cannot block unrelated clones, machines or external contributors.

After the protected merge is independently verified, record `merged` with its verified `--merge-sha`, then record `outcome_verified` only for acceptance actually established on that exact merged identity. Do not count an unmerged or stale-revision observation as a completed verified outcome. Then release integration and the writer claim:

```sh
python3 asg/tools/development_coordinator.py --repo "$ASG_WORKTREE" record --task "$ASG_TASK" --token "$ASG_TASK_TOKEN" --kind merged --head "$ASG_HEAD" --base "$ASG_BASE" --actor "$ASG_REVIEWER_ID" --evidence "$ASG_MERGE_URL" --merge-sha "$ASG_MERGE_SHA"
python3 asg/tools/development_coordinator.py --repo "$ASG_WORKTREE" record --task "$ASG_TASK" --token "$ASG_TASK_TOKEN" --kind outcome_verified --head "$ASG_HEAD" --base "$ASG_BASE" --actor "$ASG_REVIEWER_ID" --evidence "$ASG_ACCEPTANCE_REFERENCE"
python3 asg/tools/development_coordinator.py --repo "$ASG_WORKTREE" finish-integration --task "$ASG_TASK" --token "$ASG_TASK_TOKEN"
python3 asg/tools/development_coordinator.py --repo "$ASG_WORKTREE" release --task "$ASG_TASK" --token "$ASG_TASK_TOKEN"
python3 asg/tools/development_coordinator.py --repo "$ASG_WORKTREE" report
```

The integration owner reconciles shared ledger/history evidence through reviewed changes and safely synchronizes checkouts. A merge necessarily postdating its own committed log can be recorded in the next normal reviewed increment; do not start endless bookkeeping-only PRs.

## Recovery without stealing work

Expired claims continue to block task/path/writer admission, and an expired integration slot blocks integration. Clock expiry is not proof that a process stopped or a remote operation failed. Stop the affected run's new writes, inspect its registered worktree and dirty/staged changes, owned processes, remote PR/check/merge state and resource ownership. Preserve recoverable files and distinguish uncertain external effects from safely stopped work.

After the coordinator has evidence that ownership can safely end, use explicit reconciliation:

```sh
python3 asg/tools/development_coordinator.py --repo "$ASG_WORKTREE" reconcile --task "$ASG_TASK" --evidence "$ASG_RECOVERY_REFERENCE"
```

This is an operator attestation, not proof supplied by the tool. Reconcile only expired ownership after investigation. Record the reason/evidence without credentials, claim tokens or private prompts; never edit/delete the database to clear a busy slot. For corrupt state, stop coordinated writes, preserve the database and worktrees, investigate and restore from a verified copy rather than resetting it to empty. A separate clone is not a recovery mechanism.

## Speed and quality evidence

Use `record` for observed `review_changes`, `escaped_defect` and `outcome_verified` events, alongside the CI/check/review/merge events above. `report` summarizes task-to-merge elapsed time, paired observed CI wait, rework, escaped defects and verified outcomes. Counts reflect supplied observations, not an automatic quality score.

Local event timestamps measure elapsed observation intervals; they are not provider-reported queue/execution durations, and wall-clock changes affect interpretation. Label manual observations, omit unknown values rather than inventing zero, and cite real evidence. Do not count a merged infrastructure PR as a verified product workflow or interpret absence of reported defects as proof of no defects. Compare representative outcomes over multiple deliveries before promising time savings.

The tool is a cooperative same-host development aid, not an execution sandbox, secrets vault, cloud coordinator or CI authentication service. SQLite transaction safety prevents participating processes from winning the same claim; it does not prevent malicious same-user edits or enforce path permissions in the OS.

## Saved development automation

The [reviewable prompt](development_automation_prompt.txt) is the intended saved development automation instruction. Apply it through the automation management tool only after this workflow is independently reviewed and merged. Preserve the existing 15-minute interval, project, model, reasoning setting, active state and notification policy; do not edit automation files directly. Read the current saved configuration before updating and reconcile intervening changes. This prompt does not create a new schedule or authorize external marketplace actions.
