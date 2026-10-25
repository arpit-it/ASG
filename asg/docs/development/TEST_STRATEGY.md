# Test Strategy

Unit tests verify record serialization/persistence and mode/approval policy. Widget test verifies required name validation, project creation, and search. Analyze all Dart source. Compile macOS and web on this host. Other native builds require their platform toolchains and have not been established by these tests. Real device persistence, folder-picker interaction, and restart acceptance require manual verification.

Live-workspace checks cover guided intent/options/review, restored current project, chat-left/preview-right placement, narrow-screen tabs, actual counter actions, stable interaction state, invalid edit targets, failed-save preservation, and visible revision refresh after a supported instruction. The separate opt-in Qwen test exercises real inference and currently times out on this host; do not count its skipped default run as a successful integration test.
