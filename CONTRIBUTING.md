# Contributing to Automated Software Generator

Start with an existing issue or propose one bounded change using the issue forms. Outside contributors should fork the repository and open a PR; public visibility does not grant direct write access. Do not request collaborator access just to submit a contribution.

Use a dedicated branch and focused commits. Follow [AGENTS.md](AGENTS.md), [coding standards](asg/docs/development/CODING_STANDARDS.md) and the [Git workflow](asg/docs/development/GIT_WORKFLOW.md). Describe the problem, scope, acceptance criteria, test results and limits. Include `Closes #<issue>` when complete.

Run the checks in [the README](README.md) and [CI guide](asg/docs/development/CI.md), fix defects and retest. Model weights, virtual environments, build outputs, SDK paths and credentials must stay outside commits. For security issues use [private reporting](SECURITY.md), not public reproduction details containing secrets.

Main requires a PR, both GitHub Actions checks, an up-to-date branch and resolved conversations. Administrators are also subject to the rule; force pushes and branch deletion are blocked. Owner review is requested through CODEOWNERS. Independent reviewer-agent approval is required by project workflow before merge; it does not count as approval by a second GitHub account. Do not bypass failing checks or weaken repository settings to merge a change.

Fork workflows require maintainer approval for all external contributors. Approval permits the workflow to execute submitted code; inspect workflow changes, dependency hooks and code before approving. CI has read-only permissions, checkout credentials are not persisted, and GitHub Actions cannot submit approving PR reviews through the default repository token.

Actions are restricted to owner actions, GitHub-created actions and the explicitly allowed Flutter action commit. Keep top-level action references pinned to full SHAs. A deliberate Flutter-action upgrade must update both the workflow and repository allowlist after review. Do not broaden permissions or introduce pull_request_target execution of untrusted code.

The product is Flutter for Android, iOS, web, macOS, Windows and Linux; distinguish shared app behavior from macOS-specific host integrations and from verified platform builds. Use the sole [requirements/task queue](asg/docs/REQUIREMENTS.md), not historical roadmap notes, for feature scope and priority. Keep architecture/setup/security docs consistent with implementation and preserve historical evidence as explicitly historical.
