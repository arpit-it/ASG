// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import '../requirements_board.dart';
import '../structured_proposal_json.dart';

/// Review data only. Parsing never grants runner or filesystem authority.
class HtmlOperationPlan {
  HtmlOperationPlan._(this.tasks);
  final List<HtmlPlanTask> tasks;

  static const adapter = 'asg-static-html-v1';
  static const contract =
      '```asg-html-plan\n'
      '{"version":1,"adapter":"asg-static-html-v1","tasks":['
      '{"id":"check","operation":"checkSources","dependencies":[]},'
      '{"id":"preview","operation":"run","dependencies":["check"]}]}\n```';

  String get preview => tasks
      .map(
        (task) =>
            '${task.id}: ${task.operation == 'checkSources' ? 'Check exact starter source identity' : 'Start local starter preview'}; '
            'depends on: ${task.dependencies.isEmpty ? 'none' : task.dependencies.join(', ')}'
            '${task.boardTaskId == null ? '' : '; board task: ${task.boardTaskId}'}',
      )
      .join('\n');

  static HtmlOperationPlan parse(
    String content, {
    required RequirementsBoard board,
  }) {
    const invalid = FormatException('Invalid fixed HTML operation plan.');
    if (content.length > 65536) throw invalid;
    final markers = RegExp(
      r'^```asg-html-plan[^\r\n]*',
      multiLine: true,
    ).allMatches(content);
    final blocks = RegExp(
      r'^```asg-html-plan\r?\n([\s\S]*?)^```[ \t]*\r?$',
      multiLine: true,
    ).allMatches(content).toList();
    if (markers.length != 1 ||
        blocks.length != 1 ||
        content.contains('```asg-build')) {
      throw invalid;
    }
    final source = blocks.single.group(1)!;
    rejectDuplicateJsonMembers(source);
    final value = jsonDecode(source);
    if (value is! Map ||
        value.length != 3 ||
        value['version'] is! int ||
        value['version'] != 1 ||
        value['adapter'] != adapter ||
        value['tasks'] is! List) {
      throw invalid;
    }
    final rawTasks = value['tasks'] as List;
    if (rawTasks.length != 2) throw invalid;
    final tasks = <HtmlPlanTask>[];
    const operations = ['checkSources', 'run'];
    for (var i = 0; i < rawTasks.length; i++) {
      final raw = rawTasks[i];
      if (raw is! Map ||
          raw.length != (raw.containsKey('boardTaskId') ? 4 : 3) ||
          raw['id'] is! String ||
          !RegExp(r'^[A-Za-z][A-Za-z0-9_-]{0,63}$')
              .hasMatch(raw['id'] as String) ||
          raw['operation'] != operations[i] ||
          raw['dependencies'] is! List) {
        throw invalid;
      }
      final id = raw['id'] as String;
      final dependencies = raw['dependencies'] as List;
      final expected = i == 0 ? <String>[] : [tasks.first.id];
      if (tasks.any((task) => task.id == id) ||
          jsonEncode(dependencies) != jsonEncode(expected)) {
        throw invalid;
      }
      final reference = raw['boardTaskId'];
      if (raw.containsKey('boardTaskId') &&
          (reference is! String ||
              !RegExp(r'^[A-Za-z][A-Za-z0-9_-]{0,39}$').hasMatch(reference))) {
        throw invalid;
      }
      tasks.add(
        HtmlPlanTask._(id, operations[i], expected, reference as String?),
      );
    }
    board.validate();
    final mapped = tasks.where((task) => task.boardTaskId != null).toList();
    if (mapped.isNotEmpty) {
      if (mapped.length != tasks.length) throw invalid;
      final boardTasks = {for (final task in board.tasks) task.id: task};
      final prior = <String>{};
      for (final task in tasks) {
        final target = boardTasks[task.boardTaskId];
        if (target == null ||
            target.dependencies.any((id) => !prior.contains(id))) {
          throw invalid;
        }
        // A prerequisite is covered only once all its mapped operations are prior.
        if (tasks
                .where((other) => other.boardTaskId == task.boardTaskId)
                .last ==
            task) {
          prior.add(task.boardTaskId!);
        }
      }
    }
    return HtmlOperationPlan._(List.unmodifiable(tasks));
  }
}

class HtmlPlanTask {
  HtmlPlanTask._(
    this.id,
    this.operation,
    List<String> dependencies,
    this.boardTaskId,
  ) : dependencies = List.unmodifiable(dependencies);
  final String id, operation;
  final List<String> dependencies;
  final String? boardTaskId;
}
