// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'agent_session.dart';
import 'session_proposal_request.dart';
import 'structured_proposal_json.dart';

/// An exact metadata entry identity, never a model receipt or execution grant.
final class SessionProposalRequestReference {
  SessionProposalRequestReference({
    required this.projectId,
    required this.sessionId,
    required this.number,
    required this.requestSha256,
  }) {
    if (!AgentSessionTask.validId(projectId) ||
        !AgentSessionTask.validId(sessionId) ||
        number < 1 ||
        number > SessionProposalRequestJournal.maxRequests ||
        !isDigest(requestSha256)) {
      throw const FormatException('Invalid initial request reference.');
    }
  }
  static const maxEncodedBytes = 1024;
  final String projectId, sessionId, requestSha256;
  final int number;
  static bool isDigest(String value) =>
      RegExp(r'^[a-f0-9]{64}$').hasMatch(value);
  static String fingerprint(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  factory SessionProposalRequestReference.fromRequest(
    SessionProposalRequest request,
  ) {
    if (request.status != SessionProposalRequestStatus.returnedValidated) {
      throw const FormatException(
        'Only a recorded validated return can be referenced.',
      );
    }
    return SessionProposalRequestReference(
      projectId: request.projectId,
      sessionId: request.sessionId,
      number: request.number,
      requestSha256: fingerprint(jsonEncode(request.toJson())),
    );
  }
  bool matches(SessionProposalRequest request) =>
      request.status == SessionProposalRequestStatus.returnedValidated &&
      projectId == request.projectId &&
      sessionId == request.sessionId &&
      number == request.number &&
      requestSha256 == fingerprint(jsonEncode(request.toJson()));

  Map<String, Object> toJson() => {
    'version': 1,
    'projectId': projectId,
    'sessionId': sessionId,
    'number': number,
    'requestSha256': requestSha256,
  };
  String encode() => jsonEncode(toJson());
  factory SessionProposalRequestReference.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value.length != 5 ||
        value['version'] is! int ||
        value['version'] != 1 ||
        value['projectId'] is! String ||
        value['sessionId'] is! String ||
        value['number'] is! int ||
        value['requestSha256'] is! String) {
      throw const FormatException('Invalid initial request reference.');
    }
    return SessionProposalRequestReference(
      projectId: value['projectId'] as String,
      sessionId: value['sessionId'] as String,
      number: value['number'] as int,
      requestSha256: value['requestSha256'] as String,
    );
  }
  factory SessionProposalRequestReference.decode(String raw) {
    if (utf8.encode(raw).length > maxEncodedBytes) {
      throw const FormatException(
        'Initial request reference exceeds its bound.',
      );
    }
    final decoded = jsonDecode(raw);
    rejectDuplicateJsonMembers(raw);
    final value = SessionProposalRequestReference.fromJson(decoded);
    if (value.encode() != raw) {
      throw const FormatException(
        'Initial request reference must be canonical.',
      );
    }
    return value;
  }
}

/// Original selected bytes survive preparation/retry. No source is restored here.
final class SessionProposalOrigin {
  SessionProposalOrigin({
    required this.reference,
    required this.requestSessionRecord,
  }) : requestSession = decodeSession(requestSessionRecord) {
    if (requestSession.projectId != reference.projectId ||
        requestSession.sessionId != reference.sessionId ||
        requestSession.cancellationRequested) {
      throw const FormatException('Initial request origin identity changed.');
    }
  }
  final SessionProposalRequestReference reference;
  final String requestSessionRecord;
  final AgentSession requestSession;

  static AgentSession decodeSession(String raw) {
    if (utf8.encode(raw).length > AgentSession.maxEncodedBytes) {
      throw const FormatException('Initial request session exceeds its bound.');
    }
    final decoded = jsonDecode(raw);
    rejectDuplicateJsonMembers(raw);
    return AgentSession.fromJson(decoded);
  }

  void requireRequest(SessionProposalRequest request) {
    if (!reference.matches(request) ||
        request.sessionSha256 !=
            SessionProposalRequestReference.fingerprint(requestSessionRecord) ||
        request.approvalSha256 !=
            SessionProposalRequestReference.fingerprint(
              jsonEncode(requestSession.approval.toJson()),
            ) ||
        !requestSession.tasks.items.any(
          (task) =>
              task.id == request.boardTaskId &&
              task.requirementId == request.requirementId,
        )) {
      throw const FormatException(
        'Initial request does not match its retained origin.',
      );
    }
  }

  /// Admission may follow earlier runs. Only the next admission is one append.
  void requireExtension(AgentSession admission) {
    final original = requestSession;
    final added = admission.dispatches.length - original.dispatches.length;
    if (admission.projectId != original.projectId ||
        admission.sessionId != original.sessionId ||
        admission.cancellationRequested ||
        !admission.approval.matches(original.approval) ||
        jsonEncode(admission.tasks.toJson()) !=
            jsonEncode(original.tasks.toJson()) ||
        added < 0 ||
        admission.revision != original.revision + added ||
        jsonEncode(
              admission.dispatches
                  .take(original.dispatches.length)
                  .map((d) => d.toJson())
                  .toList(),
            ) !=
            jsonEncode(original.dispatches.map((d) => d.toJson()).toList())) {
      throw const FormatException(
        'Admission does not retain the initial request session prefix.',
      );
    }
  }
}
