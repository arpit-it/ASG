# ASG documentation

ASG is a Flutter application targeting Android, iOS, web, macOS, Windows and Linux. Included platform runners do not establish tested device support. Managed MLX setup and the current independent Flutter web generator host are macOS-specific; other platforms retain supported app features and runtime connection controls.

Current delivery: F01–F09, F13 and F14 are delivered within their recorded acceptance boundaries. F10 authored-check contract review, the scoped initial F17 macOS/web baseline and F18 standalone Ask are delivered; additional adapters (F11), isolated self-development (F12) and portability improvements remain queued. Consult the canonical requirements queue for exact status, final acceptance and merge evidence.

[Requirements and task queue](REQUIREMENTS.md) is the single source for product scope, new tasks, dependencies, acceptance criteria and completion status. Its [current application architecture](REQUIREMENTS.md#current-application-architecture-and-implemented-behavior) describes the implemented MVC layers, workflows, storage namespaces, platform matrix, model limits and remaining boundaries.

The [expanded workflow contract](REQUIREMENTS.md#expanded-product-workflows-and-support-contract--28-october-2026) records planned engineering Ask/Code Lab modes, Git repository workflows, language/framework coverage, instruction-file scheduling and model selection. Cloud service creation/connection is the final phase; these additions are requirements, not delivered capabilities.

The [user-owned Hugging Face cloud direction](REQUIREMENTS.md#user-owned-hugging-face-cloud-and-pricing-direction--28-october-2026) keeps local ASG free and scopes optional user-billed Spaces/API/endpoints to final F23. Cloud support remains planned. ASG-owned code/docs use [Mozilla Public License 2.0](../../LICENSE) with [owner attribution](../../NOTICE); [responsible-use guidance](../../RESPONSIBLE_USE.md) is separate from that grant.

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
- [Product acceptance evidence](development/PRODUCT_ACCEPTANCE.md)
- [Standalone engineering Ask](development/ASK.md)
- [Dependencies](development/DEPENDENCIES.md)
- [Security](development/SECURITY.md)

## Setup

- [Android Studio](setup/ANDROID_STUDIO.md)
- [Local Qwen](setup/LOCAL_QWEN.md)
- [Qwen Streaming](setup/QWEN_STREAMING.md)
- [Runtime Setup](setup/RUNTIME_SETUP.md)
- [Coding model catalog](setup/CODING_MODEL_CATALOG.md)

## History and continuity

- [Agent Memory](history/AGENT_MEMORY.md)
- [Progress](history/PROGRESS.md)
- [Roadmap](history/ROADMAP.md)
- [Initial foundation notes](history/INITIAL_FOUNDATION.md)

Repository contribution instructions and vulnerability reporting remain at the repository root. Platform asset READMEs remain beside their assets.
