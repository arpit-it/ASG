// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'agent_session.dart';
import 'model_request_provenance.dart';
import 'repair_attempt.dart';
import 'source_edit_proposal.dart';
import 'structured_proposal_json.dart';

String _fingerprint(String value) =>
    sha256.convert(utf8.encode(value)).toString();
bool _digest(String value) => RegExp(r'^[a-f0-9]{64}$').hasMatch(value);
const _maxSafeInteger = 9007199254740991;
bool _number(int value) => value > 0 && value <= _maxSafeInteger;
Map<String, dynamic> _shape(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !keys.every(value.containsKey)) {
    throw const FormatException('Invalid selected repair provenance fields.');
  }
  return value;
}

Object? _decodeRecord(String raw) {
  try {
    final value = jsonDecode(raw);
    rejectDuplicateJsonMembers(raw);
    return value;
  } catch (_) {
    throw const FormatException(
      'Selected repair provenance JSON is unreadable.',
    );
  }
}

AgentSession _session(String raw) {
  if (utf8.encode(raw).length > AgentSession.maxEncodedBytes) {
    throw const FormatException('Selected repair session exceeds its bound.');
  }
  final decoded = _decodeRecord(raw);
  return AgentSession.fromJson(decoded);
}

/// Immutable request intent, separate from the unchanged v1 repair journal.
/// Pure validation neither proves external cause nor grants execution authority.
final class SelectedRepairRequest {
  SelectedRepairRequest({
    required this.projectId,
    required this.attemptNumber,
    required this.boardTaskId,
    required this.requirementId,
    required this.requirementsRevision,
    required this.reservationSha256,
    required this.failedRunSha256,
    required this.workingSha256,
    required this.requestSessionRecord,
    required Map<String, String> sourceSha256,
    required this.modelRequest,
  }) : sourceSha256 = Map.unmodifiable(
         Map.fromEntries(
           sourceSha256.entries.toList()
             ..sort((a, b) => a.key.compareTo(b.key)),
         ),
       ),
       requestSession = _session(requestSessionRecord) {
    modelRequest.validate();
    if (![
          projectId,
          boardTaskId,
          requirementId,
        ].every(AgentSessionTask.validId) ||
        !_number(attemptNumber) ||
        requirementsRevision < 0 ||
        requirementsRevision > _maxSafeInteger ||
        ![reservationSha256, failedRunSha256].every(_digest) ||
        (workingSha256 != null && !_digest(workingSha256!)) ||
        requestSession.projectId != projectId ||
        requestSession.cancellationRequested ||
        !requestSession.approval.approved ||
        !requestSession.tasks.items.any(
          (t) => t.id == boardTaskId && t.requirementId == requirementId,
        ) ||
        modelRequest.responseModel != null ||
        modelRequest.outputTokens !=
            ModelRequestProvenance.sourceOutputTokens ||
        this.sourceSha256.isEmpty ||
        this.sourceSha256.length > SourceEditProposal.maxFiles ||
        this.sourceSha256.entries.any(
          (e) =>
              e.key.length > 256 ||
              !SourceEditProposal.isSourcePath(e.key) ||
              !_digest(e.value),
        )) {
      throw const FormatException(
        'Invalid selected repair request provenance.',
      );
    }
    if (utf8.encode(encode()).length > maxEncodedBytes) {
      throw const FormatException(
        'Selected repair provenance exceeds its bound.',
      );
    }
  }
  static const prefix = 'studio.selectedRepairRequest.v1.';
  static const maxEncodedBytes = 2 * 1024 * 1024;
  final String projectId,
      boardTaskId,
      requirementId,
      reservationSha256,
      failedRunSha256;
  final String? workingSha256;
  final String requestSessionRecord;
  final int attemptNumber, requirementsRevision;
  final Map<String, String> sourceSha256;
  final ModelRequestProvenance modelRequest;
  final AgentSession requestSession;
  String get storageKey => '$prefix$projectId.$attemptNumber';
  static String fingerprint(String value) => _fingerprint(value);
  Map<String, Object?> toJson() => {
    'version': 1,
    'projectId': projectId,
    'attemptNumber': attemptNumber,
    'boardTaskId': boardTaskId,
    'requirementId': requirementId,
    'requirementsRevision': requirementsRevision,
    'reservationSha256': reservationSha256,
    'failedRunSha256': failedRunSha256,
    'workingSha256': workingSha256,
    'requestSessionRecord': requestSessionRecord,
    'sourceSha256': sourceSha256,
    'modelRequest': modelRequest.toJson(),
  };
  String encode() => jsonEncode(toJson());
  factory SelectedRepairRequest.fromJson(Object? value) {
    final data = _shape(value, {
      'version',
      'projectId',
      'attemptNumber',
      'boardTaskId',
      'requirementId',
      'requirementsRevision',
      'reservationSha256',
      'failedRunSha256',
      'workingSha256',
      'requestSessionRecord',
      'sourceSha256',
      'modelRequest',
    });
    final sources = data['sourceSha256'];
    if (data['version'] is! int ||
        data['version'] != 1 ||
        data['attemptNumber'] is! int ||
        data['requirementsRevision'] is! int ||
        ![
          'projectId',
          'boardTaskId',
          'requirementId',
          'reservationSha256',
          'failedRunSha256',
          'requestSessionRecord',
        ].every((k) => data[k] is String) ||
        (data['workingSha256'] != null && data['workingSha256'] is! String) ||
        sources is! Map<String, dynamic> ||
        sources.values.any((v) => v is! String)) {
      throw const FormatException(
        'Invalid selected repair request provenance.',
      );
    }
    return SelectedRepairRequest(
      projectId: data['projectId'] as String,
      attemptNumber: data['attemptNumber'] as int,
      boardTaskId: data['boardTaskId'] as String,
      requirementId: data['requirementId'] as String,
      requirementsRevision: data['requirementsRevision'] as int,
      reservationSha256: data['reservationSha256'] as String,
      failedRunSha256: data['failedRunSha256'] as String,
      workingSha256: data['workingSha256'] as String?,
      requestSessionRecord: data['requestSessionRecord'] as String,
      sourceSha256: sources.cast<String, String>(),
      modelRequest: ModelRequestProvenance.fromJson(data['modelRequest']),
    );
  }
  factory SelectedRepairRequest.decode(String raw) {
    if (utf8.encode(raw).length > maxEncodedBytes) {
      throw const FormatException(
        'Selected repair provenance exceeds its bound.',
      );
    }
    final decoded = _decodeRecord(raw);
    final value = SelectedRepairRequest.fromJson(decoded);
    if (value.encode() != raw) {
      throw const FormatException(
        'Selected repair provenance must be canonical.',
      );
    }
    return value;
  }

  /// Reconstruct requested-only settings explicitly. withResponseModel(null)
  /// intentionally retains a response and cannot reproduce a reserved entry.
  static String reservedFingerprint(RepairAttempt attempt) {
    final settings = attempt.modelRequest;
    if (settings == null) {
      throw const FormatException('Repair request settings unavailable.');
    }
    return _fingerprint(
      jsonEncode(
        RepairAttempt(
          number: attempt.number,
          startedAt: attempt.startedAt,
          failure: attempt.failure,
          status: RepairAttemptStatus.reserved,
          modelRequest: ModelRequestProvenance(
            model: settings.model,
            outputTokens: settings.outputTokens,
          ),
        ).toJson(),
      ),
    );
  }

  /// Checks jointly supplied historical facts, without current storage/approval.
  void requireAttempt(RepairAttempt attempt) {
    try {
      final retained = RepairAttempt.fromJson(attempt.toJson());
      final settings = retained.modelRequest;
      if (retained.number != attemptNumber ||
          settings == null ||
          settings.model != modelRequest.model ||
          settings.outputTokens != modelRequest.outputTokens ||
          reservedFingerprint(retained) != reservationSha256 ||
          _fingerprint(jsonEncode(retained.failure.toJson())) !=
              failedRunSha256 ||
          retained.failure.snapshot.approval?.matches(
                requestSession.approval,
              ) !=
              true ||
          retained.failure.snapshot.tasks?.any(
                (t) => t.boardTaskId == boardTaskId,
              ) !=
              true ||
          sourceSha256.entries.any(
            (e) => retained.failure.snapshot.sources[e.key] != e.value,
          ) ||
          (retained.proposal?.changes.any(
                (c) => sourceSha256[c.path] != _fingerprint(c.before),
              ) ??
              false)) {
        throw const FormatException();
      }
    } catch (_) {
      throw const FormatException(
        'Selected repair provenance does not match the retained attempt.',
      );
    }
  }
}

/// Exact jointly retained identities. Constructing this DTO is not authorization.
final class SelectedRepairRequestReference {
  SelectedRepairRequestReference({
    required this.projectId,
    required this.attemptNumber,
    required this.attemptSha256,
    required this.originSha256,
  }) {
    if (!AgentSessionTask.validId(projectId) ||
        !_number(attemptNumber) ||
        ![attemptSha256, originSha256].every(_digest) ||
        utf8.encode(encode()).length > maxEncodedBytes) {
      throw const FormatException('Invalid selected repair reference.');
    }
  }
  static const maxEncodedBytes = 1024;
  final String projectId, attemptSha256, originSha256;
  final int attemptNumber;
  factory SelectedRepairRequestReference.forProposed(
    SelectedRepairRequest origin,
    RepairAttempt attempt,
  ) {
    origin.requireAttempt(attempt);
    if (attempt.status != RepairAttemptStatus.proposed) {
      throw const FormatException(
        'Only a recorded proposed repair can be referenced.',
      );
    }
    return SelectedRepairRequestReference(
      projectId: origin.projectId,
      attemptNumber: origin.attemptNumber,
      attemptSha256: _fingerprint(jsonEncode(attempt.toJson())),
      originSha256: _fingerprint(origin.encode()),
    );
  }
  Map<String, Object> toJson() => {
    'version': 1,
    'projectId': projectId,
    'attemptNumber': attemptNumber,
    'attemptSha256': attemptSha256,
    'originSha256': originSha256,
  };
  String encode() => jsonEncode(toJson());
  factory SelectedRepairRequestReference.fromJson(Object? value) {
    final data = _shape(value, {
      'version',
      'projectId',
      'attemptNumber',
      'attemptSha256',
      'originSha256',
    });
    if (data['version'] is! int ||
        data['version'] != 1 ||
        data['projectId'] is! String ||
        data['attemptNumber'] is! int ||
        data['attemptSha256'] is! String ||
        data['originSha256'] is! String) {
      throw const FormatException('Invalid selected repair reference.');
    }
    return SelectedRepairRequestReference(
      projectId: data['projectId'] as String,
      attemptNumber: data['attemptNumber'] as int,
      attemptSha256: data['attemptSha256'] as String,
      originSha256: data['originSha256'] as String,
    );
  }
  factory SelectedRepairRequestReference.decode(String raw) {
    if (utf8.encode(raw).length > maxEncodedBytes) {
      throw const FormatException(
        'Selected repair reference exceeds its bound.',
      );
    }
    final decoded = _decodeRecord(raw);
    final value = SelectedRepairRequestReference.fromJson(decoded);
    if (value.encode() != raw) {
      throw const FormatException(
        'Selected repair reference must be canonical.',
      );
    }
    return value;
  }
  void requireMatch(SelectedRepairRequest origin, RepairAttempt attempt) {
    origin.requireAttempt(attempt);
    if (attempt.status != RepairAttemptStatus.proposed ||
        projectId != origin.projectId ||
        attemptNumber != origin.attemptNumber ||
        attemptNumber != attempt.number ||
        attemptSha256 != _fingerprint(jsonEncode(attempt.toJson())) ||
        originSha256 != _fingerprint(origin.encode())) {
      throw const FormatException(
        'Exact selected repair reference is unavailable.',
      );
    }
  }
}

/// Bounded read-only projection. A proposed outcome is not an accepted repair.
final class SelectedRepairHistoryEntry {
  const SelectedRepairHistoryEntry({
    required this.attempt,
    this.origin,
    this.reference,
  });
  final RepairAttempt attempt;
  final SelectedRepairRequest? origin;
  final SelectedRepairRequestReference? reference;
}

final class SelectedRepairHistory {
  SelectedRepairHistory(
    Iterable<SelectedRepairHistoryEntry> entries, {
    required this.omittedProjectAttempts,
  }) : entries = List.unmodifiable(entries);
  final List<SelectedRepairHistoryEntry> entries;
  final int omittedProjectAttempts;
}
