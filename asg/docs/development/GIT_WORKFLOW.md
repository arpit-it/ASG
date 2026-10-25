# Repository workflow

Repository: https://github.com/arpit-it/ASG

The owner authorized a one-time reviewed baseline push to main for issue #1. All later implementations use issue-linked branches and pull requests. Preserve unrelated changes and stage explicit implementation paths.

## Naming and communication

Use direct issue-based branch names such as `<issue-number>-<short-description>` without `codex/`, `chatgpt/`, or any assistant/provider identification. Do not add Codex, ChatGPT, OpenAI, or similar identification to branch names or PR titles/bodies. If a working identity is needed, use exactly "ASG is working". Do not announce routine branch creation. This user preference applies to all future and scheduled runs; historical branch names remain unchanged.

## Work cycle

1. Create/reuse an issue with scope and acceptance criteria before coding.
2. Inspect the checkout and fetch origin; do not overwrite local work.
3. Start `<issue>-<slug>` from current origin/main, using a worktree when needed.
4. Implement, test and review the relevant diff.
5. Commit related changes and push the feature branch with an upstream.
6. Open a PR against main, link the issue and include validation/limitations.
7. Resolve CI/review findings, retest, and have an independent reviewer agent approve the final revision and merge only after required checks pass.
8. Verify the remote result and update project memory/progress.

Typical commands (substitute the actual issue/branch):

```sh
git status --short --branch
git fetch origin
git switch -c <issue>-<slug> origin/main
git diff --check
git diff --stat
git add <related-paths>
git diff --cached
git commit -m "feat: describe the verified change"
git push -u origin <issue>-<slug>
```

Do not run checkout commands blindly with unrelated changes. Never reset/discard user edits, force-push main, include model caches/environments/secrets, or claim skipped inference tests verify the model. Prefer CLI or connected GitHub tools; a signed-in browser/IDE is a valid fallback. Keep credentials out of logs and files.

## Historical foundation issues (completed; not a task queue)

- #1: publish the reviewed Flutter/streaming-Qwen baseline.
- #2: CI checks and issue/PR templates (first separate implementation branch).
- #3: independently generated, built/tested Flutter source projects.
- #4: transactional storage and durable interaction state.

The 15 minute schedule follows AGENTS.md and the issue-first workflow; it must not repeatedly publish directly to main.

Scheduled runs must finish active work first and create at most one necessary new issue only if existing issues do not cover the current gap. Reviewer-agent delegation and conditional reviewer merges are explicitly authorized by the user.

## Current selection and documentation

Only [Requirements](../REQUIREMENTS.md) defines active/queued tasks. F01, F02 and F13 are delivered; F03 is awaiting its final acceptance review. Do not select later work until the current increment is verified merged. A broad documentation audit must reconcile current behavior with source/tests, keep historical evidence clearly labeled, and add at most one justified stable F ID when an uncovered documented capability exists. Include documentation in the same reviewed branch; any changed PR revision requires a fresh final review. Check merge/issue closure before marking Done.
