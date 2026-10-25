import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_definition.dart';
import '../models/chat_message.dart';
import '../models/project.dart';

class ApplicationSnapshot {
  const ApplicationSnapshot(this.definition, this.messages, this.revision);
  final AppDefinition definition;
  final List<ChatMessage> messages;
  final int revision;
}

class ApplicationStore {
  ApplicationStore(this.preferences);
  final SharedPreferences preferences;
  static Future<ApplicationStore> open() async =>
      ApplicationStore(await SharedPreferences.getInstance());
  ApplicationSnapshot load(StudioProject project) {
    final raw = preferences.getString('studio.application.v1.${project.id}');
    if (raw == null) return ApplicationSnapshot(starter(project), const [], 1);
    final data = jsonDecode(raw) as Map<String, dynamic>;
    return ApplicationSnapshot(
      AppDefinition.fromJson(data['definition'] as Map<String, dynamic>),
      (data['messages'] as List)
          .map((m) => ChatMessage.fromJson(Map<String, dynamic>.from(m as Map)))
          .toList(),
      data['revision'] as int,
    );
  }

  Future<void> save(String id, ApplicationSnapshot state) async {
    if (!await preferences.setString(
      'studio.application.v1.$id',
      jsonEncode({
        'definition': state.definition.toJson(),
        'messages': state.messages.map((m) => m.toJson()).toList(),
        'revision': state.revision,
      }),
    )) {
      throw StateError('Application update could not be saved.');
    }
  }

  AppDefinition starter(StudioProject project) {
    final idea = project.description.toLowerCase();
    return AppDefinition(
      title: project.name,
      theme: 'indigo',
      elements: [
        AppElement(
          id: 'welcome',
          kind: ElementKind.heading,
          label: project.name,
        ),
        if (RegExp(r'task|planner|todo|inventory|record|item|habit')
            .hasMatch(idea))
          const AppElement(
            id: 'tasks',
            kind: ElementKind.taskList,
            label: 'My items',
          )
        else
          AppElement(
            id: 'intro',
            kind: ElementKind.text,
            label: project.description.split('\n').first.isEmpty
                ? 'Welcome to your application.'
                : project.description.split('\n').first,
          ),
      ],
    );
  }
}
