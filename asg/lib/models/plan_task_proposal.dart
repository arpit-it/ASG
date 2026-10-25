import 'dart:convert';

import 'requirements_board.dart';
import 'structured_proposal_json.dart';

/// Planning data only. This graph cannot supply executable commands or results.
class PlanTaskProposal {
  PlanTaskProposal._(this.tasks);
  final List<DevelopmentTask> tasks;

  static PlanTaskProposal parse(String content) {
    const message =
        'Request one valid asg-tasks proposal with task IDs, existing '
        'requirement IDs, titles and dependencies. Tasks are planning data only.';
    if (content.length > 65536) throw const FormatException(message);
    final markers = RegExp(
      r'^```asg-tasks[^\r\n]*',
      multiLine: true,
    ).allMatches(content).length;
    final blocks = RegExp(
      r'^```asg-tasks\r?\n([\s\S]*?)^```[ \t]*\r?$',
      multiLine: true,
    ).allMatches(content).toList();
    if (markers != 1 || blocks.length != 1) {
      throw const FormatException(message);
    }
    try {
      final json = blocks.single.group(1)!;
      final value = jsonDecode(json);
      rejectDuplicateJsonMembers(json);
      if (value is! Map ||
          value.length != 2 ||
          value['version'] is! int ||
          value['version'] != 1 ||
          value['tasks'] is! List) {
        throw const FormatException(message);
      }
      final raw = value['tasks'] as List;
      if (raw.isEmpty || raw.length > 200) throw const FormatException(message);
      final tasks = <DevelopmentTask>[];
      for (final task in raw) {
        if (task is! Map ||
            task.length != 4 ||
            task['id'] is! String ||
            task['requirementId'] is! String ||
            task['title'] is! String ||
            task['dependencies'] is! List ||
            (task['dependencies'] as List).any((d) => d is! String)) {
          throw const FormatException(message);
        }
        tasks.add(
          DevelopmentTask(
            id: task['id'] as String,
            requirementId: task['requirementId'] as String,
            title: task['title'] as String,
            dependencies: (task['dependencies'] as List).cast<String>(),
          ),
        );
      }
      return PlanTaskProposal._(List.unmodifiable(tasks));
    } on FormatException {
      throw const FormatException(message);
    }
  }

  /// Additive only: never overwrite a task or accept model-declared completion.
  RequirementsBoard addTo(RequirementsBoard current) {
    final result = RequirementsBoard(
      requirements: current.requirements,
      tasks: [...current.tasks, ...tasks],
    );
    result.validate();
    return result;
  }

  String get preview => tasks
      .map(
        (t) =>
            '${t.id}: ${t.title} [${t.requirementId}] — queued; dependencies: '
            '${t.dependencies.isEmpty ? 'none' : t.dependencies.join(', ')}',
      )
      .join('\n');
}
