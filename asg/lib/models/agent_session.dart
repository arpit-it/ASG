// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'plan_approval.dart';
import 'requirements_board.dart';

/// Frozen session membership, not a scheduler or an execution grant.
final class AgentSessionTask {
  AgentSessionTask._(this.id, this.requirementId, List<String> dependencies)
    : dependencies = List.unmodifiable(dependencies);

  final String id, requirementId;
  final List<String> dependencies;

  static bool validId(String value) =>
      value.isNotEmpty &&
      value.length <= 128 &&
      !RegExp(r'[^a-zA-Z0-9_-]').hasMatch(value);

  factory AgentSessionTask.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value.length != 3 ||
        value['id'] is! String ||
        value['requirementId'] is! String ||
        value['dependencies'] is! List) {
      throw const FormatException('Invalid session task.');
    }
    final id = value['id'] as String;
    final requirementId = value['requirementId'] as String;
    final dependencies = value['dependencies'] as List;
    if (!validId(id) ||
        !validId(requirementId) ||
        dependencies.length > AgentSessionTasks.maxTasks ||
        dependencies.any((item) => item is! String || !validId(item)) ||
        dependencies.toSet().length != dependencies.length ||
        dependencies.contains(id)) {
      throw const FormatException('Invalid session task binding.');
    }
    return AgentSessionTask._(id, requirementId, dependencies.cast<String>());
  }

  Map<String, Object> toJson() => {
    'id': id,
    'requirementId': requirementId,
    'dependencies': dependencies.toList(),
  };
}

/// A bounded, dependency-closed snapshot of selected planning tasks.
/// Authored status/title changes do not imply execution progress here.
final class AgentSessionTasks {
  AgentSessionTasks._(List<AgentSessionTask> items)
    : items = List.unmodifiable(items);

  static const maxTasks = 64;
  final List<AgentSessionTask> items;

  factory AgentSessionTasks.fromBoardTasks(List<DevelopmentTask> tasks) =>
      AgentSessionTasks.fromJson([
        for (final task in tasks)
          {
            'id': task.id,
            'requirementId': task.requirementId,
            'dependencies': task.dependencies.toList(),
          },
      ]);

  factory AgentSessionTasks.fromJson(Object? value) {
    if (value is! List || value.isEmpty || value.length > maxTasks) {
      throw const FormatException('Session must contain 1–64 selected tasks.');
    }
    final items = value.map(AgentSessionTask.fromJson).toList();
    final byId = {for (final task in items) task.id: task};
    if (byId.length != items.length ||
        items.any(
          (task) => task.dependencies.any((id) => !byId.containsKey(id)),
        )) {
      throw const FormatException('Session task membership is inconsistent.');
    }
    final visiting = <String>{}, visited = <String>{};
    void visit(String id) {
      if (visited.contains(id)) return;
      if (!visiting.add(id)) {
        throw const FormatException('Session task dependency cycle.');
      }
      for (final dependency in byId[id]!.dependencies) {
        visit(dependency);
      }
      visiting.remove(id);
      visited.add(id);
    }

    for (final task in items) {
      visit(task.id);
    }
    return AgentSessionTasks._(items);
  }

  List<Map<String, Object>> toJson() => [
    for (final task in items) task.toJson(),
  ];
}

/// An observed run in the selected approved task context, never task completion.
final class AgentSessionDispatch {
  AgentSessionDispatch({
    required this.boardTaskId,
    required this.runNumber,
    required this.dispatchId,
  });
  final String boardTaskId, dispatchId;
  final int runNumber;
  Map<String, Object> toJson() => {
    'boardTaskId': boardTaskId,
    'runNumber': runNumber,
    'dispatchId': dispatchId,
  };
  factory AgentSessionDispatch.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value.length != 3 ||
        value['boardTaskId'] is! String ||
        value['runNumber'] is! int ||
        value['dispatchId'] is! String) {
      throw const FormatException('Invalid session dispatch reference.');
    }
    return AgentSessionDispatch(
      boardTaskId: value['boardTaskId'] as String,
      runNumber: value['runNumber'] as int,
      dispatchId: value['dispatchId'] as String,
    );
  }
}

/// Durable observational data only. It cannot dispatch, resume or complete work.
final class AgentSession {
  AgentSession._({
    required this.sessionId,
    required this.projectId,
    required this.revision,
    required this.approval,
    required this.tasks,
    required List<AgentSessionDispatch> dispatches,
    required this.cancellationRequested,
  }) : dispatches = List.unmodifiable(dispatches);

  static const prefix = 'studio.agentSession.v1.';
  static const maxDispatches = 128;
  static const maxEncodedBytes = 256 * 1024;
  final String sessionId, projectId;
  final int revision;
  final PlanApproval approval;
  final AgentSessionTasks tasks;
  final List<AgentSessionDispatch> dispatches;
  final bool cancellationRequested;
  String get storageKey => '$prefix$projectId.$sessionId';

  factory AgentSession.create({
    required String sessionId,
    required String projectId,
    required PlanApproval approval,
    required AgentSessionTasks tasks,
  }) => AgentSession.fromJson({
    'version': 1,
    'sessionId': sessionId,
    'projectId': projectId,
    'revision': 0,
    'approval': approval.toJson(),
    'tasks': tasks.toJson(),
    'dispatches': <Object>[],
    'cancellationRequested': false,
  });

  AgentSession observe(AgentSessionDispatch reference) {
    if (cancellationRequested) {
      throw StateError('Session cancellation is retained.');
    }
    return AgentSession.fromJson({
      ...toJson(),
      'revision': revision + 1,
      'dispatches': [
        ...dispatches.map((item) => item.toJson()),
        reference.toJson(),
      ],
    });
  }

  AgentSession requestCancellation() {
    if (cancellationRequested) {
      throw StateError('Session cancellation already retained.');
    }
    return AgentSession.fromJson({
      ...toJson(),
      'revision': revision + 1,
      'cancellationRequested': true,
    });
  }

  Map<String, Object> toJson() => {
    'version': 1,
    'sessionId': sessionId,
    'projectId': projectId,
    'revision': revision,
    'approval': approval.toJson(),
    'tasks': tasks.toJson(),
    'dispatches': dispatches.map((item) => item.toJson()).toList(),
    'cancellationRequested': cancellationRequested,
  };

  factory AgentSession.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value.length != 8 ||
        value['version'] is! int ||
        value['version'] != 1 ||
        value['sessionId'] is! String ||
        value['projectId'] is! String ||
        value['revision'] is! int ||
        value['approval'] is! Map<String, dynamic> ||
        value['dispatches'] is! List ||
        value['cancellationRequested'] is! bool) {
      throw const FormatException('Invalid agent session.');
    }
    if (utf8.encode(jsonEncode(value)).length > maxEncodedBytes) {
      throw const FormatException('Agent session exceeds its storage bound.');
    }
    final sessionId = value['sessionId'] as String,
        projectId = value['projectId'] as String;
    final rawApproval = value['approval'] as Map<String, dynamic>;
    if (!AgentSessionTask.validId(sessionId) ||
        !AgentSessionTask.validId(projectId) ||
        rawApproval.length != 5 ||
        rawApproval['approved'] != true ||
        rawApproval['recordedAt'] is! String) {
      throw const FormatException(
        'Invalid agent session identity or approval.',
      );
    }
    final approval = PlanApproval.fromJson(rawApproval);
    if (approval.recordedAt.toUtc().toIso8601String() !=
            rawApproval['recordedAt'] ||
        utf8.encode(approval.content).length > 64 * 1024 ||
        utf8.encode(approval.context).length > 64 * 1024) {
      throw const FormatException('Invalid agent session approval snapshot.');
    }
    final tasks = AgentSessionTasks.fromJson(value['tasks']);
    final rawDispatches = value['dispatches'] as List;
    if (rawDispatches.length > maxDispatches) {
      throw const FormatException('Agent session dispatch bound exceeded.');
    }
    final dispatches = rawDispatches
        .map(AgentSessionDispatch.fromJson)
        .toList();
    final selected = tasks.items.map((item) => item.id).toSet();
    final seen = <String>{};
    for (final reference in dispatches) {
      if (!selected.contains(reference.boardTaskId) ||
          reference.runNumber < 1 ||
          reference.runNumber > 1000000 ||
          reference.dispatchId !=
              'candidate-$projectId-${reference.runNumber}:3' ||
          reference.dispatchId.length > 130 ||
          !seen.add(reference.dispatchId)) {
        throw const FormatException('Invalid agent session dispatch binding.');
      }
    }
    final cancelled = value['cancellationRequested'] as bool;
    final revision = value['revision'] as int;
    if (revision != dispatches.length + (cancelled ? 1 : 0)) {
      throw const FormatException('Invalid agent session revision.');
    }
    return AgentSession._(
      sessionId: sessionId,
      projectId: projectId,
      revision: revision,
      approval: approval,
      tasks: tasks,
      dispatches: dispatches,
      cancellationRequested: cancelled,
    );
  }
}
