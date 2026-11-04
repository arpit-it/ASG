// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import '../models/chat_message.dart';
import '../models/plan_approval.dart';
import '../models/project.dart';
import '../models/html/html_operation_plan.dart';
import 'html/html_starter_store.dart';
import 'conversation_store.dart';
import 'application_store.dart';
import 'html/html_project_store.dart';
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
    if (project.type == 'HTML') {
      final current = currentProject(project.id);
      if (context(current) != context(project)) {
        throw StateError('HTML project changed. Reopen before planning.');
      }
      final starter = HtmlProjectStore(records).resolve(project);
      return jsonEncode({
        'project': project.toJson(),
        'requirementsRevision': board.revision,
        'htmlStarter': starter.toJson(),
      });
    }
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
    if (project.type == 'HTML') {
      throw StateError(
        'HTML Plan execution is not implemented. No Flutter fallback is allowed.',
      );
    }
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

  /// Validates consent evidence only. HTML execution remains unavailable.
  void validateHtmlPlan(StudioProject project, List<ChatMessage> messages) {
    if (project.type != 'HTML') throw StateError('Not an HTML project.');
    final current = currentProject(project.id);
    final saved = ConversationStore(records).load(project.id);
    final index = latestPlan(messages);
    if (index < 0 ||
        index != latestPlan(saved) ||
        saved[index].content != messages[index].content ||
        saved[index].planContext != messages[index].planContext ||
        context(current) != context(project) ||
        saved[index].planContext != contextFor(current)) {
      throw StateError('HTML Plan changed. Reopen and review a current Plan.');
    }
    HtmlOperationPlan.parse(
      saved[index].content,
      board: RequirementsStore(records).load(project.id),
    );
  }

  bool hasCurrentHtmlConsent(
    StudioProject project,
    List<ChatMessage> messages,
  ) {
    validateHtmlPlan(project, messages);
    final approval = load(project.id);
    final index = latestPlan(messages);
    return approval != null &&
        approval.approved &&
        approval.messageIndex == index &&
        approval.content == messages[index].content &&
        approval.context == messages[index].planContext;
  }

  Future<void> _saveHtml(
    StudioProject project,
    List<ChatMessage> messages,
    bool approved,
    void Function() authorize,
  ) async {
    final storage = records;
    if (storage is! ConditionalRecordStorage) {
      throw UnsupportedError('HTML consent requires transactional storage.');
    }
    final key = 'studio.planApproval.v1.${project.id}';
    final expected = {
      for (final k in [
        key,
        'studio.projects.v1',
        'studio.chat.v1.${project.id}',
        'studio.requirements.v1.${project.id}',
        HtmlStarterStore.key,
      ])
        k: records.getString(k),
    };
    final previous = load(project.id);
    PlanApproval decision;
    if (approved) {
      validateHtmlPlan(project, messages);
      final index = latestPlan(messages);
      decision = PlanApproval(
        messageIndex: index,
        content: messages[index].content,
        context: messages[index].planContext!,
        approved: true,
        recordedAt: DateTime.now().toUtc(),
      );
    } else {
      // Withdrawal revokes the retained decision even after its Plan is stale.
      if (previous == null || !previous.approved) return;
      decision = PlanApproval(
        messageIndex: previous.messageIndex,
        content: previous.content,
        context: previous.context,
        approved: false,
        recordedAt: DateTime.now().toUtc(),
      );
    }
    authorize();
    await storage.commitRecords(
      expected: expected,
      updates: {key: jsonEncode(decision.toJson())},
      authorize: authorize,
    );
  }

  Future<void> save(
    StudioProject project,
    List<ChatMessage> messages,
    bool approved, {
    void Function()? authorize,
  }) async {
    if (project.type == 'HTML') {
      await _saveHtml(project, messages, approved, authorize ?? () {});
      return;
    }
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
