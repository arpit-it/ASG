// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

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
    late final List<BuildTask> tasks;
    late final int version;
    try {
      final json = blocks.single.group(1)!;
      final value = jsonDecode(json);
      rejectDuplicateJsonMembers(json);
      if (value is! Map ||
          value.length != 3 ||
          ![1, 2, 3, 4].contains(value['version']) ||
          value['version'] is! int ||
          value['adapter'] != 'flutter-starter') {
        throw const FormatException(message);
      }
      tasks = BuildTask.fromJson(value['tasks']);
      version = value['version'] as int;
      if (version < 3 && tasks.any((task) => task.boardTaskId != null)) {
        throw const FormatException(message);
      }
      if (value['version'] == 1 &&
          jsonEncode(tasks.map((t) => t.toJson()).toList()) !=
              jsonEncode(BuildTask.starter.map((t) => t.toJson()).toList())) {
        throw const FormatException(message);
      }
    } on FormatException {
      throw const FormatException(message);
    }
    // Report fixed mapping diagnostics without echoing JSON or project text.
    if (version >= 3) {
      if (board == null) {
        throw const FormatException(
          'Board task mapping needs the current requirements board. '
          'Reopen the project and draft a current Plan.',
        );
      }
      _validateBoardTasks(tasks, board, distinct: version == 3);
    }
    return BuildPlan._(tasks);
  }

  /// Board completion is manual evidence, never permission to skip a command.
  /// Every prerequisite must be mapped into this same approved execution graph.
  static void _validateBoardTasks(
    List<BuildTask> tasks,
    RequirementsBoard board, {
    required bool distinct,
  }) {
    try {
      board.validate();
    } on FormatException {
      throw const FormatException(
        'The requirements board is invalid. Correct its tasks and dependencies '
        'before drafting a new Plan.',
      );
    }
    final boardTasks = {for (final task in board.tasks) task.id: task};
    final mapped = <String, Set<String>>{};
    for (final task in tasks) {
      final reference = task.boardTaskId;
      if (reference == null || !boardTasks.containsKey(reference)) {
        throw const FormatException(
          'A mapped board task is missing. Use existing board task IDs for '
          'every operation in a new Plan.',
        );
      }
      if (distinct && mapped.containsKey(reference)) {
        throw const FormatException(
          'Version 3 needs distinct board tasks. Use version 4 when several '
          'operations belong to the same board task.',
        );
      }
      (mapped[reference] ??= <String>{}).add(task.id);
    }
    final ancestors = <String, Set<String>>{};
    for (final task in tasks) {
      final prior = <String>{
        for (final dependency in task.dependencies) dependency,
        for (final dependency in task.dependencies) ...ancestors[dependency]!,
      };
      if (boardTasks[task.boardTaskId]!.dependencies.any(
        (dependency) =>
            mapped[dependency] == null ||
            !prior.containsAll(mapped[dependency]!),
      )) {
        throw const FormatException(
          'A board prerequisite is missing or incomplete in the execution graph. '
          'Map every prerequisite operation before each dependent operation, '
          'then review and approve a new Plan.',
        );
      }
      ancestors[task.id] = prior;
    }
  }
}
