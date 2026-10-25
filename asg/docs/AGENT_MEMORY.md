# Durable project memory

## Goal and user decisions

Build Automated Software Generator: a local-first application that can eventually create, develop, run, test and maintain many types of software from natural-language instructions. The app leads the process; the user supplies intent, chooses proposed options and reviews meaningful decisions. Do not confuse the bounded live prototype with a completed arbitrary-code generator.

Active Git repository: `/Users/arpitsinha/AndroidStudioProjects/ASG`. Flutter root: `asg/`. Preserve the initial repository history, user changes and app identifiers. Use MVC and the root AGENTS.md / CODING_STANDARDS.md. The old Documents/ChatGPT project directory is historical, not the active checkout.

User requirements: support downloaded model files and explicit repository downloads; top-right runtime setup FAB; restore current project at entry; desktop chat left, live application preview right; instructions should apply to the application and refresh its preview; show thinking/writing loaders and stream assistant text. Use existing Qwen3.5-9B. User explicitly approved disabling App Sandbox for this macOS build to launch a selected host runtime, with preference preservation. That approval does not authorize changing operating-system protections or unrelated applications.

## Current implementation and limits

Flutter six-platform runners, MVC foundation, saved projects, guided setup, runtime setup, local model bridge, bounded interactive prototype renderer, structured edit validation and saved application revisions are implemented. No arbitrary source generator/build orchestration/export/deployment or full self-development engine is complete. Original full brief is MASTER_REQUIREMENTS.md. Current behavior and limitations are documented in LIVE_WORKSPACE.md and RUNTIME_SETUP.md.

Before the current streaming change, 40 tests and macOS/Android/web builds passed. Real structured edits on the full 19 GB PyTorch BF16 model timed out twice; do not describe those as successful integration tests.

## Latest verified increment: MLX timeout fix and streaming

The Qwen timeout fix is implemented and verified. Isolated runtime `tools/.mlx-venv` uses pinned dependencies in tools/requirements-mlx.txt. Existing original BF16 weights were converted locally into ignored `.runtime-models/qwen3.5-9b-4bit`; originals were preserved and no model downloaded. Benchmark: 2.59-second load, 5.89 seconds total for a short structured response, 67.8 tokens/sec, 5.29 GB reported peak memory. Use QWEN_STREAMING.md for the current restart command. Check runtime health; do not assume a background process survives between runs.

The local bridge supports MLX and legacy Torch, SSE phases/tokens/heartbeats/DONE/error, bounded requests, a single inference worker and cancellation. The Flutter provider streams tokens. Edit chat streams only the human-readable summary while retaining validated edit JSON internally. Discuss chat also streams. Always-visible loaders show thinking/writing/checking/applying; Stop cancels before save. Complete validated edits persist before refreshing the actual live prototype. Model settings and project keys are preserved. The accidental prompt-record compile issue has been fixed.

Latest completed checks: analysis passed, 48 regular Flutter tests passed (one live test skipped by default), the real opt-in custom Qwen edit test passed with built-in handling disabled and assertions for multiple streamed text chunks, and 4 Python HTTP/SSE tests passed. macOS, Android debug and web builds all passed. Do not rerun large conversions or reimplement streaming if already verified.

Public repository: https://github.com/arpit-it/ASG.git. Local origin already matches and remote main matched the local initial commit when checked. The user now explicitly authorized a one-time reviewed baseline push to main (#1). Every subsequent implementation must start with a GitHub issue, use a separate codex/<issue>-<slug> branch, and open a PR targeting main. Issue/branch/commit/feature-push/PR actions are authorized; the user explicitly authorizes an independent reviewer agent to merge after approving the final revision and confirming required checks pass. Preserve unrelated changes and never force-push main. See AGENTS.md and GIT_WORKFLOW.md.

Next priority: maintain the working streaming/runtime and data safety, then advance the documented roadmap toward transactional storage, safe source/template generation, deterministic builds/tests and actual independent application previews. Current interpreter prototypes remain a bounded first slice, not arbitrary source-code generation. Pick one coherent verified increment per scheduled run.

## Hourly continuation policy

The user requested hourly feature development based on the requirements. Each run should read this memory, project instructions, requirements, roadmap and progress; finish current work first; implement one coherent next increment; test it and fix bugs; record verified results, limitations and next steps. Preserve last working behavior. Never fake inference/build/test/preview success. Respect explicit approvals and execution limits; do not install system-wide software, silently download large models, run arbitrary untrusted code, push/merge/publish or replace a stable executable without authorization. Stay quiet on unchanged/non-actionable runs; notify meaningful progress, completion, failures or required user decisions.

## GitHub workflow update — 25 October 2026

Created publication issue #1, CI/template issue #2, source-generation issue #3 and storage/state issue #4 through the signed-in GitHub session. Baseline published to main as 3dc6142174e7d282a40ce70bab8eb8b2ba4c2705; exact tree independently reviewed. Issue #1 is complete. GitHub plugin installation was confirmed after the user approved access. Do not assume terminal credentials or gh are configured; verify available tools/auth safely. Do not expose credentials. First post-baseline implementation should address #2 on codex/2-ci-workflow and open a PR. Update this section with final pushed commit/PR evidence.

Latest schedule policy: prefer existing/in-progress issues, create at most one necessary new issue per run, implement/test/fix/retest to completion, then independent reviewer-agent review and conditional merge. Do not expand the backlog speculatively or bypass failing checks.

Issue #2 adds CI and focused issue/PR templates on codex/2-ci-workflow. CI checks formatting, analysis, default Flutter tests, web build and lightweight Python fixtures. Real inference remains opt-in and must never be inferred from skipped CI tests. See CI.md.

Issue #2 completed: independent reviewer merged PR #5 as 2bad70a31371e23715aff22333d1bb5d826a808f after both GitHub CI jobs passed; issue #2 closed. Issue #6 updates both READMEs to the requirements and current capabilities on codex/6-requirements-readme, replacing outdated preview/runtime claims.

## Issue #4: transactional storage and interaction durability

Branch codex/4-transactional-storage implements Sembast native-file/web-IndexedDB repositories, atomic validated v1 preference migration with originals retained, strict corruption errors, and durable task/completion/counter/note state. Chat waits for pending writes, generation disables preview input, save errors expose retry, and project navigation waits for committed changes. See STORAGE.md; do not migrate again or delete retained preferences. Real Chrome IndexedDB rollback/reopen test is added to CI. User additionally requested repository protection (#8), to follow this issue before source generation #3. Keep visibility unchanged pending an explicit user choice; reviewer-agent independence is not a separate GitHub account approval.

Issue #4 complete: reviewer merged PR #9 as 2b6602a223e9945ce3f3adb120c647afc13866ec after all CI, 15 independent focused tests and final-head review; issue closed. Issue #8 on codex/8-repository-safeguards adds owner/contribution/security guidance. Main protection was saved and re-opened to verify required PRs, both GitHub Actions checks, strict up-to-date state, resolved conversations, admin enforcement and blocked force pushes/deletions. External fork runs require all-contributor approval; Actions allowlist is limited to owner/GitHub plus the pinned Flutter action. Read-only default token and disabled Actions approving PRs confirmed. Private vulnerability reporting enabled. No collaborators invited; visibility remains public. Formal second-account approvals remain off because the agent uses owner identity. Do not claim secret push protection or paid scanning is enabled.

## Issue #3: independent Flutter generation

Repository safeguards #8 merged as fb6432be through protected PR #10. Branch codex/3-flutter-generation implements a fixed Flutter web MVC export from the current validated prototype/reviewed requirements. Explicit approval creates only a new canonical folder, runs bounded offline Flutter resolve/analyze/test/build through the trusted Python helper, persists actual outcomes/failures and can retry unchanged source/dependency metadata with corrected tools. Verified compiled output is served via an owned token-scoped loopback URL and opened on request. Do not claim arbitrary model-written source, native generation, continuous exported-source edits or a security sandbox. See GENERATION.md. Keep all existing streaming/storage behavior and repository protections intact. CI includes actual generated-project verification; do not count default-skipped generation/Qwen tests as real verification outside their explicit runs.

Issue #3 implementation is tracked by [PR #11](https://github.com/arpit-it/ASG/pull/11) on codex/3-flutter-generation. Its final exact-revision independent review, CI results and merge commit are the authoritative delivery evidence; inspect that PR before starting a later increment. Local validation and feature boundaries are recorded in GENERATION.md / PROGRESS.md.

## Issue #12: generated snapshot input status

Confirmed source-generation PR #11 merged as 979dc4f2447888a454aef90ffaf0e751c9040481 and issue #3 closed. One new necessary issue #12 addresses old generated builds being displayed alongside newer chat/prototype inputs without a status distinction. Branch codex/12-generated-snapshot-status shares the exact v1 serialization through GenerationInput, compares saved application/requirements hashes, and labels current/earlier/unknown snapshots with explicit preview/open actions. Status is derived, not persisted; no record/schema migration or existing-folder rewriting. Golden v1 hashes, application/interaction/requirements changes, missing identity, raw-history preservation and UI preview actions have regression tests. Source/output integrity checks and execution approval remain unchanged.

Issue #12 delivery is tracked by [PR #13](https://github.com/arpit-it/ASG/pull/13), branch codex/12-generated-snapshot-status. Its final exact-revision review, required CI and merge record are the authoritative completion evidence; inspect the PR before starting the next increment.

Issue #14 (`codex/14-session-selection`) addresses an actual session-save concurrency/lifecycle gap after confirming no open issues or PRs. Shared create/select busy guards and home interaction/focus exclusion protect pending selection. Seven regression tests cover delayed writes, failures/retry, overlap, disposal and toolbar/workspace locking. Storage formats and project content are unchanged; inspect the linked PR for final exact-revision review, CI and merge evidence before starting another increment.

Issue #14 delivery: [PR #15](https://github.com/arpit-it/ASG/pull/15), branch `codex/14-session-selection`. Local formatter/analyzer, 93 default tests (two opt-in tests skipped) and web build passed. Final exact-head independent review, required CI results and merge SHA are authoritative in that PR.
