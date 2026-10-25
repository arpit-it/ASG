# Flutter MVC architecture

ASG is a Flutter application targeting Android, iOS, web, macOS, Windows and Linux. Included platform runners do not establish tested device support. Managed MLX setup and the current independent Flutter web generator host are macOS-specific; other platforms retain supported app features and runtime connection controls.

Views call controller actions; controllers coordinate services and publish state after validation and successful persistence. Models hold typed domain data and pure validation. Services own storage, HTTP, filesystem and platform integration. Controllers contain no widgets or BuildContext. Views own navigation and text/focus lifecycles; injected services make failures and async disposal testable.

| Area | Main components and responsibilities |
| --- | --- |
| Creation/session | ProjectBlueprint, ProjectDiscovery, ProjectWizardController, StudioSessionController and StudioSessionStore guide intent/options/review and restore the selected project. |
| Prototype editing | AppDefinition/AppElement, AppWorkspaceController, ApplicationEditor, LocalApplicationActions and ApplicationStore validate, persist and render interpreted controls in LiveApplicationView. |
| Planning | ChatController and ConversationStore stream/save Discuss, Plan and advisory Review. RequirementsController/RequirementsStore manage the structured board. PlanTaskProposal/PlanTaskImport preview and explicitly import queued planning tasks. |
| Approval | PlanApprovalStore rereads exact durable Plan, project, board revision and prototype revision/definition. BuildPlan validates the allowlisted starter contract; prose cannot grant tool permissions. |
| Source generation | SourceGenerationController coordinates GenerationInput, SourceGenerationStore and conditional GenerationHost implementations. The macOS host creates a new fixed Flutter web MVC project and runs bounded trusted verification. BuildTask progress derives from actual saved command results. SourceReviewController delegates confined candidate checks to SourceCandidateController; guarded atomic promotion hands a separately validated preview host back to Build. |
| Runtime | RuntimeSetupController, conditional RuntimeHost, RuntimeConnection and RuntimeSetupStore manage explicit local setup/connection. LocalModel implements streaming ModelProvider transport with deadlines/cancellation. |
| Persistence | RecordStorage abstracts transactional native Sembast and browser IndexedDB through StudioDatabase; retained preference migration and corrupt-record isolation preserve evidence. |

The default workspace is a chat-left/preview-right interpreted prototype; narrow screens use tabs. A generated compiled web preview is a separate explicitly launched snapshot. General source synthesis beyond reviewed scoped Dart replacements, new adapters, repairs, rollback and self-development remain in the [requirements queue](../REQUIREMENTS.md). The app's fixed desktop pane widths are not yet user-resizable (F14).

See [storage](STORAGE.md), [generation](GENERATION.md), [workspace behavior](LIVE_WORKSPACE.md), [runtime setup](../setup/RUNTIME_SETUP.md) and [coding standards](../development/CODING_STANDARDS.md). Stable storage keys and legacy payloads remain readable; new Plan contexts require a fresh draft rather than inferred legacy approval.
