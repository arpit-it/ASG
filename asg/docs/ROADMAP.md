# Roadmap

1. Flutter foundation and planning records (current partial milestone). 2. Transactional storage, editable requirements, real settings and existing-project import. 3. Verified local model adapter and persisted Discuss/Plan chat with approval. 4. Safe Flutter generator, deterministic build/test pipeline, actual preview, bounded repairs. 5. Isolated self-development and manual merge approval. Other template types remain metadata choices only.


Current increment: MLX local inference, real custom-edit verification, streamed chat and visible progress are implemented. Continue from durable AGENT_MEMORY.md and PROGRESS.md. Next: transactional project/application storage and a safe independently buildable Flutter source-template vertical slice. Expand framework adapters incrementally toward the general software-generation goal; do not describe bounded prototypes as completed source generation.

Issue #4 implements transactional native/web storage with retained legacy migration and durable prototype interactions. Next: owner-requested repository safeguards (#8), then the independent Flutter source-generation vertical slice (#3).

Issue #8 safeguards completed via reviewer-merged PR #10 (fb6432be). Issue #3 adds the first independent Flutter web MVC source snapshot, real verification and local compiled preview, with recovery for unchanged generated inputs. Next priorities should derive from actual gaps in this slice; arbitrary model source synthesis, richer requirements editing, native/framework adapters and bounded repairs remain future work.

Issue #3 implementation is tracked by [PR #11](https://github.com/arpit-it/ASG/pull/11) on codex/3-flutter-generation. Its final exact-revision independent review, CI results and merge commit are the authoritative delivery evidence; inspect that PR before starting a later increment. Local validation and feature boundaries are recorded in GENERATION.md / PROGRESS.md.

Source generation #3 merged as 979dc4f2 in PR #11. Issue #12 makes saved-export input staleness visible without rewriting existing projects. Continue selecting one necessary increment from actual application gaps; no speculative issue backlog is added.

Issue #12 delivery is tracked by [PR #13](https://github.com/arpit-it/ASG/pull/13), branch codex/12-generated-snapshot-status. Its final exact-revision review, required CI and merge record are the authoritative completion evidence; inspect the PR before starting the next increment.

Snapshot-status PR #13 merged as add0d358. Issue #14 fixes observed asynchronous project-selection races on `codex/14-session-selection`; its linked PR carries final review/check/merge evidence. Continue choosing a single necessary increment from observed gaps rather than adding speculative backlog.

Issue #14 delivery: [PR #15](https://github.com/arpit-it/ASG/pull/15), branch `codex/14-session-selection`. Local formatter/analyzer, 93 default tests (two opt-in tests skipped) and web build passed. Final exact-head independent review, required CI results and merge SHA are authoritative in that PR.

Project selection #14 completed in PR #15 (18637ace). Issue #16 on `codex/16-edit-project-details` adds editable current-project name/requirements while preserving the working app and chat, with future-export metadata and stale-export status. Richer structured requirements/approval, existing-source import and other framework adapters remain future increments; select from observed gaps rather than speculative backlog.

Issue #16 delivery: [PR #17](https://github.com/arpit-it/ASG/pull/17), branch `codex/16-edit-project-details`. Local formatter/analyzer, 107 default tests and web/macOS debug builds passed. Final exact-head independent review, required CI and merge SHA are authoritative in that PR.

Editable details #16 completed in PR #17 (621c70d2). Issue #18 on `codex/18-dashboard-build-status` exposes actual latest saved generation outcomes and input staleness on the dashboard, replacing stale placeholders. Full build history/timestamps and live process reporting are not implied; continue choosing one real gap at a time.

Issue #18 delivery: [PR #19](https://github.com/arpit-it/ASG/pull/19), branch `codex/18-dashboard-build-status`. Local formatter/analyzer, 115 default tests and web build passed. Final exact-head independent review, required CI results and merge SHA are authoritative in that PR.

Issue #18 review also required real startup isolation: preserve damaged post-migration project app/generation records and surface per-key errors while healthy projects remain accessible. Strict initial migration, global records, physical-file safeguards and write validation remain. Final PR review/CI must cover the revised production database path.

Issue #18 corrected-revision validation: formatter/analyzer, 117 default Flutter tests, actual Chrome IndexedDB test, web build and macOS debug build passed. PR #19 must receive fresh exact-head review and required CI after the production-storage correction; default-skipped Qwen/generation are not fresh live verification.


Issue #18 completed through independent reviewer-merged PR #19 as 2fce778be8e3fb29495c87b43f0707001394ee2f. Final corrected head fd417afd was approved; both required CI jobs passed, including actual Chrome IndexedDB and generated-project verification. Issue closed and main synchronized; unrelated tracked IDE edits remain preserved.

Issue #20 (`codex/20-creation-recovery`) repairs partial creation: after project persistence succeeds but session selection fails, show a saved-but-not-opened explanation and an explicit selection-only retry. Duplicate IDs are rejected before writing. Retry rereads canonical metadata, retains the previous workspace until selection commits and rejects missing/ambiguous records. Busy/disposal guards remain; opening an existing project dismisses recovery. No rollback, schema change or saved-project deletion. Six new controller/widget regressions cover write failures, repeated retries, stale metadata, duplicate IDs, missing/ambiguous records, disposal, overlap and the wizard-to-retry flow.

Issue #20 validation: formatter/analyzer, 123 default Flutter tests (live Qwen and real generation skipped), and web build passed. Existing MLX runtime health is ready/idle; no fresh inference claim. Final linked PR supplies independent exact-head review, required CI and merge evidence.


Issue #22 (`codex/22-discussion-plan-mode`) adds the documented conversational Plan mode beside Discuss, reached through the workspace's Discuss and plan action. Both modes have no file/command/application-edit tools. Plan prompts request requirements, feasibility/dependencies, tasks, acceptance criteria, risks and review/approval; persisted v1 content is visibly labeled as an unapproved draft. Reopening defaults to Discuss while retaining history; no schema migration or executable approved-plan engine is implied. Mode changes and duplicate sends are blocked during requests. Cancellation before the initial save completes prevents inference; partial/empty/failed replies never publish a plan. Nine deterministic controller/widget/native-reopen regressions cover persistence failures, cancellation/disposal, history, no application writes and workspace navigation.

Issue #22 local validation: analyzer, 132 default Flutter tests (three opt-in tests skipped), web build and the explicit real local Qwen planning test passed. Real planning streamed multiple chunks and persisted the labeled draft using the existing MLX runtime; this verifies the bounded conversation flow, not arbitrary implementation. The linked PR will carry exact-revision independent review, required CI and merge evidence.

Issue #22 additional validation: formatter passed with no changes; macOS debug build passed and the existing opt-in real Qwen instruction test passed, confirming a custom instruction still streams, saves a revision and refreshes the prototype. The stable installed app was not replaced.

Issue #22 delivery: [PR #23](https://github.com/arpit-it/ASG/pull/23), branch `codex/22-discussion-plan-mode`. The published implementation tree exactly matches the locally tested tree. Independent review, required CI and protected merge evidence are recorded in the PR; until verified there, treat delivery as pending. No executable approved-plan workflow is claimed.

Issue #22 independent review found three blockers: cancellation remained available during the final commit, Back allowed reopening before pending writes completed, and keyboard plus enlarged text overflowed the Plan screen. Fixed non-cancellable Saving response state, busy navigation/Back locking, and a whole-screen scroll fallback for constrained viewports. Added delayed initial/final write + attempted Back/reopen regressions and a 320×640 / 1.5 text scale / 250px keyboard regression. Twelve focused regressions and 135 default Flutter tests now pass; analyzer passes. Final corrected-head review and CI remain required in PR #23.

Issue #22 corrected revision also passed formatter, web and macOS debug rebuilds and a fresh opt-in real local Qwen planning run. Independent reviewer reran the original layout probe and all twelve deterministic planning regressions successfully; exact published-head approval and required CI must still be verified in PR #23 before merge.


Issue #24 (`codex/24-response-save-recovery`) retains completed Discuss/Plan responses when the final conversation write fails. The visible response is explicitly unsaved; Retry saving response retries only persistence, without another model request. New requests, mode changes and navigation remain blocked until the response commits; retry is non-cancellable while saving. Initial-request failures and partial/model-failure behavior remain unchanged. No schema or application/source writes. Recovery is in memory: closing the process before saving can still lose the unsaved reply; the screen explains keeping it open. Four regression tests cover both modes, repeated failure, exact labels/content, duplicate retries, disposal, durable history and the Plan widget retry/navigation flow. Final PR supplies independent exact-revision review, CI and merge evidence.

Issue #24 local validation: formatter/analyzer passed; 139 default Flutter tests passed with three opt-in skips; web build passed. Existing Qwen MLX health ready/idle; no fresh inference verification claimed. Unrelated IDE edits are preserved.


## Advisory prototype Review — issue #26

Branch `codex/26-prototype-review` adds Review beside Discuss and Plan. Each request reads a fresh bounded prototype definition/revision and typed saved generation outcome/input match through a read-only evidence service. Unsaved starter fallbacks, unreadable records and omitted oversized definitions are explicit. Saved builds remain historical evidence; Review does not inspect source, execute checks, approve plans or modify application/generated records. Reports request requirement coverage, gaps/risks, verification still needed and next steps, with a persisted advisory/no-new-checks label. This is a bounded first Review increment, not the full deterministic Review engine in MASTER_REQUIREMENTS.md §4.4.

Existing busy, cancellation, navigation and save-only retry guards apply. New regressions cover fresh evidence, current/stale/unknown builds, corruption, context bounds, labeled/reopened history, Review save retries and keyboard/enlarged-text layout. The mode selector scrolls horizontally when necessary. The workspace Discuss, plan and review entry opens all three assistance modes. Final issue-linked PR supplies exact-revision independent review, CI and merge evidence.

Issue #26 local validation: formatter/analyzer, 144 default Flutter tests (four opt-in skips), web build and the explicit real Qwen Review smoke passed. The live review streamed multiple chunks and persisted its labeled report without changing the supplied application. Final UI-label verification and macOS debug build are recorded in the linked PR. The stable installed app is unchanged.

Issue #26 final revision: formatter/analyzer and all 144 default tests passed again after the workspace entry-label change; web and macOS debug builds passed. Independent review and required CI remain pending until verified in the linked PR.
