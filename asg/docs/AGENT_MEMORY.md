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
