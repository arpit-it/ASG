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
