// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'agent_session.dart';
import 'model_request_provenance.dart';
import 'source_edit_proposal.dart';

enum SessionProposalRequestStatus {
  reserved,
  returnedValidated,
  failedLocally,
  cancelledLocally,
}

/// Historical request metadata, never restored source or execution permission.
final class SessionProposalRequest {
  SessionProposalRequest({
    required this.number,
    required this.projectId,
    required this.sessionId,
    required this.boardTaskId,
    required this.requirementId,
    required this.requirementsRevision,
    required this.sessionSha256,
    required this.approvalSha256,
    required this.workingSha256,
    required Map<String, String> sourceSha256,
    required this.modelRequest,
    required this.startedAt,
    this.status = SessionProposalRequestStatus.reserved,
    this.finishedAt,
    Map<String, String> returnedSha256 = const {},
  }) : sourceSha256 = Map.unmodifiable(
         Map.fromEntries(
           sourceSha256.entries.toList()
             ..sort((a, b) => a.key.compareTo(b.key)),
         ),
       ),
       returnedSha256 = Map.unmodifiable(
         Map.fromEntries(
           returnedSha256.entries.toList()
             ..sort((a, b) => a.key.compareTo(b.key)),
         ),
       ) {
    _validate();
  }

  final int number, requirementsRevision;
  final String projectId, sessionId, boardTaskId, requirementId;
  final String sessionSha256, approvalSha256, workingSha256;
  final Map<String, String> sourceSha256, returnedSha256;
  final ModelRequestProvenance modelRequest;
  final DateTime startedAt;
  final DateTime? finishedAt;
  final SessionProposalRequestStatus status;

  static bool _digest(String value) =>
      RegExp(r'^[a-f0-9]{64}$').hasMatch(value);
  static bool _sources(Map<String, String> values) =>
      values.isNotEmpty &&
      values.length <= SourceEditProposal.maxFiles &&
      values.entries.every(
        (e) => SourceEditProposal.isSourcePath(e.key) && _digest(e.value),
      );

  void _validate() {
    modelRequest.validate();
    final returned = status == SessionProposalRequestStatus.returnedValidated;
    if (number < 1 ||
        number > SessionProposalRequestJournal.maxRequests ||
        requirementsRevision < 0 ||
        ![
          projectId,
          sessionId,
          boardTaskId,
          requirementId,
        ].every(AgentSessionTask.validId) ||
        ![sessionSha256, approvalSha256, workingSha256].every(_digest) ||
        !_sources(sourceSha256) ||
        modelRequest.outputTokens !=
            ModelRequestProvenance.sourceOutputTokens ||
        (modelRequest.responseModel != null &&
            modelRequest.responseModel != modelRequest.model) ||
        !startedAt.isUtc ||
        (status == SessionProposalRequestStatus.reserved) !=
            (finishedAt == null) ||
        (finishedAt != null &&
            (!finishedAt!.isUtc || finishedAt!.isBefore(startedAt))) ||
        (returned ? !_sources(returnedSha256) : returnedSha256.isNotEmpty) ||
        returnedSha256.entries.any(
          (e) =>
              !sourceSha256.containsKey(e.key) ||
              sourceSha256[e.key] == e.value,
        ) ||
        (!returned && modelRequest.responseModel != null)) {
      throw const FormatException('Invalid session proposal request metadata.');
    }
  }

  SessionProposalRequest finish(
    SessionProposalRequestStatus outcome, {
    required DateTime at,
    Map<String, String> returnedSha256 = const {},
    String? responseModel,
  }) {
    if (status != SessionProposalRequestStatus.reserved ||
        outcome == SessionProposalRequestStatus.reserved) {
      throw StateError(
        'An unresolved request and terminal local outcome are required.',
      );
    }
    return SessionProposalRequest(
      number: number,
      projectId: projectId,
      sessionId: sessionId,
      boardTaskId: boardTaskId,
      requirementId: requirementId,
      requirementsRevision: requirementsRevision,
      sessionSha256: sessionSha256,
      approvalSha256: approvalSha256,
      workingSha256: workingSha256,
      sourceSha256: sourceSha256,
      modelRequest: responseModel == null
          ? modelRequest
          : ModelRequestProvenance(
              model: modelRequest.model,
              outputTokens: modelRequest.outputTokens,
              responseModel: responseModel,
            ),
      startedAt: startedAt,
      status: outcome,
      finishedAt: at,
      returnedSha256: returnedSha256,
    );
  }

  Map<String, Object?> toJson() => {
    'number': number,
    'projectId': projectId,
    'sessionId': sessionId,
    'boardTaskId': boardTaskId,
    'requirementId': requirementId,
    'requirementsRevision': requirementsRevision,
    'sessionSha256': sessionSha256,
    'approvalSha256': approvalSha256,
    'workingSha256': workingSha256,
    'sourceSha256': sourceSha256,
    'modelRequest': modelRequest.toJson(),
    'startedAt': startedAt.toIso8601String(),
    'status': status.name,
    'finishedAt': finishedAt?.toIso8601String(),
    'returnedSha256': returnedSha256,
  };

  factory SessionProposalRequest.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value.length != 15 ||
        value['number'] is! int ||
        value['requirementsRevision'] is! int ||
        ![
          'projectId',
          'sessionId',
          'boardTaskId',
          'requirementId',
          'sessionSha256',
          'approvalSha256',
          'workingSha256',
          'startedAt',
          'status',
        ].every((key) => value[key] is String) ||
        !(value['finishedAt'] == null || value['finishedAt'] is String) ||
        !value.containsKey('finishedAt')) {
      throw const FormatException('Invalid session proposal request metadata.');
    }
    Map<String, String> hashes(Object? input) {
      if (input is! Map<String, dynamic> ||
          input.values.any((v) => v is! String)) {
        throw const FormatException('Invalid source fingerprints.');
      }
      return input.cast<String, String>();
    }

    final status = SessionProposalRequestStatus.values.where(
      (s) => s.name == value['status'],
    );
    if (status.length != 1) {
      throw const FormatException('Invalid request outcome.');
    }
    final result = SessionProposalRequest(
      number: value['number'] as int,
      projectId: value['projectId'] as String,
      sessionId: value['sessionId'] as String,
      boardTaskId: value['boardTaskId'] as String,
      requirementId: value['requirementId'] as String,
      requirementsRevision: value['requirementsRevision'] as int,
      sessionSha256: value['sessionSha256'] as String,
      approvalSha256: value['approvalSha256'] as String,
      workingSha256: value['workingSha256'] as String,
      sourceSha256: hashes(value['sourceSha256']),
      modelRequest: ModelRequestProvenance.fromJson(value['modelRequest']),
      startedAt: DateTime.parse(value['startedAt'] as String),
      status: status.single,
      finishedAt: value['finishedAt'] == null
          ? null
          : DateTime.parse(value['finishedAt'] as String),
      returnedSha256: hashes(value['returnedSha256']),
    );
    if (value.keys.any((key) => !result.toJson().containsKey(key))) {
      throw const FormatException('Unknown request metadata.');
    }
    return result;
  }
}

final class SessionProposalRequestJournal {
  SessionProposalRequestJournal(Iterable<SessionProposalRequest> requests)
    : requests = List.unmodifiable(requests) {
    if (this.requests.length > maxRequests ||
        this.requests.indexed.any((item) => item.$2.number != item.$1 + 1) ||
        this.requests.any(
          (r) =>
              this.requests.first.projectId != r.projectId ||
              this.requests.first.sessionId != r.sessionId,
        )) {
      throw const FormatException('Invalid session request journal.');
    }
    if (utf8.encode(encode()).length > maxEncodedBytes) {
      throw const FormatException(
        'Session request history exceeds its storage bound.',
      );
    }
  }

  static const maxRequests = 32;
  static const maxEncodedBytes = 256 * 1024;
  final List<SessionProposalRequest> requests;
  String encode() => jsonEncode({
    'version': 1,
    'requests': requests.map((r) => r.toJson()).toList(),
  });

  factory SessionProposalRequestJournal.decode(String raw) {
    if (utf8.encode(raw).length > maxEncodedBytes) {
      throw const FormatException(
        'Session request history exceeds its storage bound.',
      );
    }
    final value = jsonDecode(raw);
    if (value is! Map<String, dynamic> ||
        value.length != 2 ||
        value['version'] != 1 ||
        value['version'] is! int ||
        value['requests'] is! List ||
        (value['requests'] as List).length > maxRequests) {
      throw const FormatException('Invalid session request journal.');
    }
    final result = SessionProposalRequestJournal(
      (value['requests'] as List).map(SessionProposalRequest.fromJson),
    );
    if (result.encode() != raw) {
      throw const FormatException('Session request history must be canonical.');
    }
    return result;
  }
}
