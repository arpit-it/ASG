import 'project.dart';

/// Prompts and labels for conversational assistance; grants no tool permissions.
extension ConversationAssistance on ConversationMode {
  String get label => this == ConversationMode.discuss ? 'Discuss' : 'Plan';

  String get instructions => switch (this) {
    ConversationMode.discuss => 'Discuss requirements for this software project. Ask clarifying questions and record decisions.',
    ConversationMode.plan =>
      'Create a draft implementation plan for this software project. '
          'Use sections: Requirements, Feasibility and dependencies, Tasks, '
          'Acceptance criteria, Risks and open questions. '
          'Separate supported behavior from proposed capabilities; ask for missing information. '
          'End with an explicit reminder that this draft needs user review and approval '
          'and that no implementation, builds or tests have been executed. '
          'Do not interpret a request to approve or build as permission to execute anything.',
    _ => throw UnsupportedError('Only Discuss and Plan are available here.'),
  };

  String labelRequest(String text) =>
      this == ConversationMode.plan ? '[Plan request]\n$text' : text;
  String labelResponse(String text) => this == ConversationMode.plan
      ? '[Plan draft — not approved]\n$text'
      : text;
}
