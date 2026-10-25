# MVC architecture

Automated Software Generator uses Model–View–Controller with services for platform and external integration.

```text
lib/
  main.dart                         Bootstrap and startup errors
  models/
    project.dart                    Project records and conversation mode
    chat_message.dart               Typed conversation record
    local_model_config.dart         Local endpoint/model configuration
  views/
    studio_app.dart                 App shell and theme
    dashboard.dart                  Project list and search UI
    project_wizard.dart             Creation form UI
    project_workspace.dart          Project navigation and panels
    model_chat.dart                 Conversation UI
    model_settings.dart             Model configuration UI
  controllers/
    base_controller.dart            Observable state and disposal guard
    dashboard_controller.dart       Search and project save workflow
    project_wizard_controller.dart  Validation, target selection, folder action
    workspace_controller.dart       Navigation and selected mode
    chat_controller.dart            Conversation load/send/save lifecycle
    model_settings_controller.dart  Configuration save and connection test
  services/
    studio_store.dart               Project persistence
    conversation_store.dart         Conversation persistence
    model_settings_store.dart       Configuration persistence
    model_provider.dart             Inference contract and injected factory
    local_model.dart                Local HTTP inference adapter
    folder_picker.dart              Platform directory picker
    execution_policy.dart           Mode/approval permission rule
```

Flow: a view calls a controller action; the controller coordinates services and updates observable state; the view listens and redraws. Controllers use Flutter's lightweight ChangeNotifier through BaseController. They contain no Material widgets or BuildContext. Views retain their widget lifecycle, TextEditingController, form keys, navigation and display decisions. Services own JSON persistence, platform APIs and HTTP. Models contain no storage or UI dependencies.

Controller dependencies can be injected for deterministic tests, including fake model providers and failing project stores. Current view constructors create and own their feature controllers, remove listeners and dispose them when closed. No additional state management package is needed.

Saved keys and schemas remain `studio.projects.v1`, `studio.localModel.v1` and `studio.chat.v1.<projectId>`. Qwen transport, cancellation behavior and runtime limits remain as documented in LOCAL_QWEN.md. This refactor adds no file execution, plan approval, source generator or preview implementation.

For a new feature: define its data model, implement an external service if needed, put its state/actions in a controller, then build its view. Keep related files focused and add controller tests independently of the UI. Future generated Flutter templates should follow the same structure when the generator is implemented.

Runtime setup adds RuntimeSetup/ModelCandidate models, RuntimeSetupController, native/unsupported RuntimeHost implementations behind a conditional factory, RuntimeConnection, RuntimeSetupStore and RuntimeSetupScreen. See RUNTIME_SETUP.md for checkpoint selection/download flow and the explicitly approved macOS host-permission boundary.

App-led creation uses ProjectBlueprint/ProjectApproach, ProjectDiscovery and ProjectWizardController. StudioSessionController/StudioSessionStore restore the current project into StudioHome. AppWorkspaceController coordinates ApplicationEditor, LocalApplicationActions and ApplicationStore; ProjectWorkspace renders chat and LiveApplicationView. The live renderer executes validated AppDefinition/AppElement controls and reports current interaction state back to the controller for subsequent edits. See LIVE_WORKSPACE.md for persistence, unsupported source generation and model-runtime limitations.
