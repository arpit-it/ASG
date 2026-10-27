// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import '../models/chat_message.dart';
import '../models/plan_approval.dart';
import '../models/project.dart';
import 'conversation_store.dart';
import 'application_store.dart';
import 'record_storage.dart';
import 'requirements_store.dart';
import 'studio_store.dart';

class PlanApprovalStore {
  PlanApprovalStore(this.records);
  final RecordStorage records;
  static String context(StudioProject project) => jsonEncode(project.toJson());
  String contextFor(StudioProject project) {
    final board = RequirementsStore(records).load(project.id);
    board.planDocument(project.name);
    final application = ApplicationStore(records).load(project);
    return jsonEncode({
      'project': project.toJson(),
      'requirementsRevision': board.revision,
      'prototypeRevision': application.revision,
      'prototypeDefinition': application.definition.toJson(),
    });
  }

  static int latestPlan(List<ChatMessage> messages) => messages.lastIndexWhere(
    (m) => m.role == 'assistant' && m.planContext != null,
  );
  PlanApproval? load(String id) {
    final raw = records.getString('studio.planApproval.v1.$id');
    return raw == null
        ? null
        : PlanApproval.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  StudioProject currentProject(String id) {
    final matches = StudioStore(records)
        .load()
        .where((p) => p.id == id)
        .toList();
    if (matches.length != 1) {
      throw StateError(
        'Project is missing or ambiguous. Reopen it before approving.',
      );
    }
    return matches.single;
  }

  /// Re-read durable evidence at the execution boundary; never trust UI state.
  PlanApproval requireCurrentApproval(StudioProject project) {
    final current = currentProject(project.id);
    final messages = ConversationStore(records).load(project.id);
    final index = latestPlan(messages);
    final approval = load(project.id);
    if (context(current) != context(project) ||
        approval == null ||
        !approval.approved ||
        index < 0 ||
        approval.messageIndex != index ||
        approval.content != messages[index].content ||
        approval.context != messages[index].planContext ||
        approval.context != contextFor(current)) {
      throw StateError(
        'Build requires the latest saved Plan approved for the current requirements and prototype. Open Plan, review a current draft and approve it.',
      );
    }
    return approval;
  }

  Future<void> save(
    StudioProject project,
    List<ChatMessage> messages,
    bool approved,
  ) async {
    // Refuse to replace unreadable approval evidence.
    load(project.id);
    final current = currentProject(project.id);
    final saved = ConversationStore(records).load(project.id);
    final index = latestPlan(messages);
    final savedIndex = latestPlan(saved);
    if (index < 0 ||
        index != savedIndex ||
        saved[index].content != messages[index].content ||
        saved[index].planContext != messages[index].planContext ||
        context(current) != context(project) ||
        (approved && saved[index].planContext != contextFor(current))) {
      throw StateError(
        'Plan or requirements changed. Reopen the project and draft a current plan.',
      );
    }
    final record = PlanApproval(
      messageIndex: index,
      content: saved[index].content,
      context: saved[index].planContext!,
      approved: approved,
      recordedAt: DateTime.now().toUtc(),
    );
    if (!await records.setString(
      'studio.planApproval.v1.${project.id}',
      jsonEncode(record.toJson()),
    )) {
      throw StateError('Plan approval could not be saved. Retry the action.');
    }
  }
}
