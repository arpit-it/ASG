import 'dart:convert';

import 'build_task.dart';
import 'requirements_board.dart';
import 'structured_proposal_json.dart';

/// A model proposal is data. Only this versioned adapter graph is executable.
class BuildPlan {
  BuildPlan._(this.tasks);
  final List<BuildTask> tasks;

  bool matchesTasks(List<BuildTask>? other) =>
      other != null &&
      jsonEncode(tasks.map((t) => t.toJson()).toList()) ==
          jsonEncode(other.map((t) => t.toJson()).toList());

  String get preview => tasks
      .map((task) {
        final label = switch (task.operation) {
          BuildOperation.resolve => 'Resolve dependencies',
          BuildOperation.analyze => 'Analyze source',
          BuildOperation.test => 'Run tests',
          BuildOperation.build => 'Build Flutter web output',
        };
        return '${task.id}: $label; depends on: '
            '${task.dependencies.isEmpty ? 'none' : task.dependencies.join(', ')}'
            '${task.boardTaskId == null ? '' : '; board task: ${task.boardTaskId}'}';
      })
      .join('\n');

  static String get starterContract =>
      '```asg-build\n${jsonEncode({'version': 1, 'adapter': 'flutter-starter', 'tasks': BuildTask.starter.map((t) => t.toJson()).toList()})}\n```';

  static BuildPlan parse(String content, {RequirementsBoard? board}) {
    const message =
        'Build needs one valid structured starter Plan. Request a new '
        'Plan explicitly scoped to generating and verifying the fixed Flutter '
        'web starter, review its tasks, then approve it. Other implementation '
        'plans remain advisory.';
    if (content.length > 65536) throw const FormatException(message);
    // Require standalone fences and reject ambiguous/multiple contracts.
    final markers = RegExp(
      r'^```asg-build[^\r\n]*',
      multiLine: true,
    ).allMatches(content).toList();
    final blocks = RegExp(
      r'^```asg-build\r?\n([\s\S]*?)^```[ \t]*\r?$',
      multiLine: true,
    ).allMatches(content).toList();
    if (markers.length != 1 || blocks.length != 1) {
      throw const FormatException(message);
    }
    try {
      final json = blocks.single.group(1)!;
      final value = jsonDecode(json);
      rejectDuplicateJsonMembers(json);
      if (value is! Map ||
          value.length != 3 ||
          ![1, 2, 3].contains(value['version']) ||
          value['version'] is! int ||
          value['adapter'] != 'flutter-starter') {
        throw const FormatException(message);
      }
      final tasks = BuildTask.fromJson(value['tasks']);
      if (value['version'] == 3) {
        if (board == null) throw const FormatException(message);
        _validateBoardTasks(tasks, board);
      } else if (tasks.any((task) => task.boardTaskId != null)) {
        throw const FormatException(message);
      }
      if (value['version'] == 1 &&
          jsonEncode(tasks.map((t) => t.toJson()).toList()) !=
              jsonEncode(BuildTask.starter.map((t) => t.toJson()).toList())) {
        throw const FormatException(message);
      }
      return BuildPlan._(tasks);
    } on FormatException {
      throw const FormatException(message);
    }
  }

  /// Board completion is manual evidence, never permission to skip a command.
  /// Every prerequisite must be mapped into this same approved execution graph.
  static void _validateBoardTasks(
    List<BuildTask> tasks,
    RequirementsBoard board,
  ) {
    board.validate();
    final boardTasks = {for (final task in board.tasks) task.id: task};
    final mapped = <String, String>{};
    for (final task in tasks) {
      final reference = task.boardTaskId;
      if (reference == null ||
          !boardTasks.containsKey(reference) ||
          mapped.containsKey(reference)) {
        throw const FormatException('Invalid board task mapping.');
      }
      mapped[reference] = task.id;
    }
    final ancestors = <String, Set<String>>{};
    for (final task in tasks) {
      final prior = <String>{
        for (final dependency in task.dependencies) dependency,
        for (final dependency in task.dependencies) ...ancestors[dependency]!,
      };
      if (boardTasks[task.boardTaskId]!.dependencies.any(
        (dependency) => !prior.contains(mapped[dependency]),
      )) {
        throw const FormatException(
          'Board prerequisite is not mapped before its dependent.',
        );
      }
      ancestors[task.id] = prior;
    }
  }
}
