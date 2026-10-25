# ASG documentation

ASG is a Flutter application targeting Android, iOS, web, macOS, Windows and Linux. Included platform runners do not establish tested device support. Managed MLX setup and the current independent Flutter web generator host are macOS-specific; other platforms retain supported app features and runtime connection controls.

Current delivery: F01 and F13 are Done; F02 is In progress. Prototype-bound approval and this documentation audit are under [PR #51](https://github.com/arpit-it/ASG/pull/51), pending final review/merge. Use the requirements ledger for authoritative status.

[Requirements and task queue](REQUIREMENTS.md) is the single source for product scope, new tasks, dependencies, acceptance criteria and completion status.

## Architecture and behavior

- [Architecture](architecture/ARCHITECTURE.md)
- [Technical Decisions](architecture/TECHNICAL_DECISIONS.md)
- [Storage](architecture/STORAGE.md)
- [Generation](architecture/GENERATION.md)
- [Live Workspace](architecture/LIVE_WORKSPACE.md)

## Development and validation

- [Coding Standards](development/CODING_STANDARDS.md)
- [Git Workflow](development/GIT_WORKFLOW.md)
- [CI](development/CI.md)
- [SDLC](development/SDLC.md)
- [Test Strategy](development/TEST_STRATEGY.md)
- [Dependencies](development/DEPENDENCIES.md)
- [Security](development/SECURITY.md)

## Setup

- [Android Studio](setup/ANDROID_STUDIO.md)
- [Local Qwen](setup/LOCAL_QWEN.md)
- [Qwen Streaming](setup/QWEN_STREAMING.md)
- [Runtime Setup](setup/RUNTIME_SETUP.md)

## History and continuity

- [Agent Memory](history/AGENT_MEMORY.md)
- [Progress](history/PROGRESS.md)
- [Roadmap](history/ROADMAP.md)
- [Initial foundation notes](history/INITIAL_FOUNDATION.md)

Repository contribution instructions and vulnerability reporting remain at the repository root. Platform asset READMEs remain beside their assets.
