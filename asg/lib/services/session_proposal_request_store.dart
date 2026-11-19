// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/agent_session.dart';
import '../models/agent_session_binding.dart';
import '../models/model_request_provenance.dart';
import '../models/project.dart';
import '../models/session_proposal_request.dart';
import '../models/session_proposal_reference.dart';
import '../models/source_edit_proposal.dart';
import 'agent_session_admission.dart';
import 'record_storage.dart';
import 'requirements_store.dart';
import 'source_generation_store.dart';

/// A session's bounded initial-request observations. Never dispatches or replays.
final class SessionProposalRequestStore {
  SessionProposalRequestStore(this.records, this.projectId, this.sessionId) {
    if (!AgentSessionTask.validId(projectId) ||
        !AgentSessionTask.validId(sessionId)) {
      throw const FormatException('Invalid session request identity.');
    }
  }
  final RecordStorage records;
  final String projectId, sessionId;
  static const prefix = 'studio.sessionProposalRequests.v1.';
  String get key => '$prefix$projectId.$sessionId';
  SessionProposalRequest? _owned;
  late String _requestSessionRecord;
  SessionProposalOrigin? _returnedOrigin;

  /// Available only after the matching returned-outcome commit succeeds.
  SessionProposalOrigin? get returnedOrigin => _returnedOrigin;
  Map<String, String?> _returnContext = const {};
  bool _outcomeWriteAttempted = false;

  static String fingerprint(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  static SessionProposalRequestJournal decode(String key, String raw) {
    if (!key.startsWith(prefix)) {
      throw const FormatException('Invalid session request key.');
    }
    final parts = key.substring(prefix.length).split('.');
    if (parts.length != 2 || !parts.every(AgentSessionTask.validId)) {
      throw const FormatException('Invalid session request key.');
    }
    final journal = SessionProposalRequestJournal.decode(raw);
    if (journal.requests.any(
      (r) => r.projectId != parts[0] || r.sessionId != parts[1],
    )) {
      throw const FormatException('Session request journal identity changed.');
    }
    return journal;
  }

  SessionProposalRequestJournal _decode(String? raw) =>
      raw == null ? SessionProposalRequestJournal([]) : decode(key, raw);

  /// Read-only, including withdrawn sessions. No current approval is inferred.
  SessionProposalRequestJournal load() => _decode(records.getString(key));

  SessionProposalRequest referenced(SessionProposalRequestReference reference) {
    final requests = load().requests;
    if (reference.projectId != projectId ||
        reference.sessionId != sessionId ||
        reference.number > requests.length ||
        !reference.matches(requests[reference.number - 1])) {
      throw const FormatException(
        'Exact returned request reference is unavailable.',
      );
    }
    return requests[reference.number - 1];
  }

  Future<SessionProposalRequest> reserve({
    required StudioProject project,
    required AgentSessionBinding binding,
    required String workingRecord,
    required Map<String, String> originals,
    required ModelRequestProvenance modelRequest,
    required void Function() authorize,
  }) async {
    if (_owned != null ||
        project.id != projectId ||
        binding.session.sessionId != sessionId) {
      throw StateError(
        'Request reservation identity changed or is already owned.',
      );
    }
    final storage = records;
    if (storage is! ConditionalRecordStorage) {
      throw StateError(
        'Atomic storage is required for session request history.',
      );
    }
    final snapshot = Map<String, String>.unmodifiable(originals);
    if (snapshot.isEmpty ||
        snapshot.length > SourceEditProposal.maxFiles ||
        snapshot.entries.any(
          (e) =>
              !SourceEditProposal.isSourcePath(e.key) ||
              e.value.length > SourceEditProposal.maxText,
        ) ||
        jsonEncode(snapshot).length > SourceEditProposal.maxResponse ||
        modelRequest.responseModel != null) {
      throw const FormatException('Invalid initial request input.');
    }
    final admission = AgentSessionRunAdmission(records, project, binding);
    final sessionRecord = admission.requireCurrent();
    SessionProposalOrigin.decodeSession(sessionRecord);
    final expected = <String, String?>{
      ...AgentSessionAdmission(records, project).approvalRecords(),
      binding.session.storageKey: sessionRecord,
      'studio.generation.v1.$projectId': workingRecord,
      key: records.getString(key),
    };
    if (records.getString('studio.generation.v1.$projectId') != workingRecord) {
      throw StateError('Working build changed before request reservation.');
    }
    final working = SourceGenerationStore(records).load(projectId);
    final sources = {
      for (final e in snapshot.entries) e.key: fingerprint(e.value),
    };
    if (working == null ||
        sources.entries.any((e) => working.sources[e.key] != e.value)) {
      throw StateError(
        'Initial source snapshot does not match the recorded working build.',
      );
    }
    final board = RequirementsStore(records).load(projectId);
    final task = board.tasks.singleWhere((t) => t.id == binding.boardTaskId);
    final previous = _decode(expected[key]);
    if (previous.requests.length >= SessionProposalRequestJournal.maxRequests) {
      throw StateError('Session request history is full. No request started.');
    }
    final request = SessionProposalRequest(
      number: previous.requests.length + 1,
      projectId: projectId,
      sessionId: sessionId,
      boardTaskId: binding.boardTaskId,
      requirementId: task.requirementId,
      requirementsRevision: board.revision,
      sessionSha256: fingerprint(sessionRecord),
      approvalSha256: fingerprint(
        jsonEncode(binding.session.approval.toJson()),
      ),
      workingSha256: fingerprint(workingRecord),
      sourceSha256: sources,
      modelRequest: modelRequest,
      startedAt: DateTime.now().toUtc(),
    );
    final next = SessionProposalRequestJournal([...previous.requests, request])
        .encode();
    await storage.commitRecords(
      expected: expected,
      updates: {key: next},
      authorize: () {
        authorize();
        if (admission.requireCurrent() != sessionRecord ||
            expected.entries.any((e) => records.getString(e.key) != e.value)) {
          throw StateError(
            'Initial request context changed during reservation.',
          );
        }
      },
    );
    _requestSessionRecord = sessionRecord;
    _returnedOrigin = null;
    _owned = request;
    _returnContext = Map.unmodifiable({...expected}..remove(key));
    _outcomeWriteAttempted = false;
    return request;
  }

  /// One attempt only: a failed outcome write leaves durable intent unresolved.
  /// Local failures/cancellation can be observed after approval withdrawal.
  Future<void> finish(
    SessionProposalRequestStatus status, {
    SourceEditProposal? proposal,
    void Function()? authorizeReturn,
  }) async {
    final owned = _owned;
    if (owned == null) return;
    if (_outcomeWriteAttempted) {
      throw StateError(
        'Request outcome persistence is unresolved. Reopen history.',
      );
    }
    if (status == SessionProposalRequestStatus.reserved ||
        (status == SessionProposalRequestStatus.returnedValidated) !=
            (proposal != null) ||
        (proposal != null && authorizeReturn == null)) {
      throw StateError('A truthful terminal request outcome is required.');
    }
    if (proposal != null &&
        proposal.changes.any(
          (change) =>
              fingerprint(change.before) != owned.sourceSha256[change.path],
        )) {
      throw const FormatException(
        'Returned source does not match request fingerprints.',
      );
    }
    final expected = records.getString(key);
    final previous = _decode(expected).requests.toList();
    if (previous.length < owned.number ||
        jsonEncode(previous[owned.number - 1].toJson()) !=
            jsonEncode(owned.toJson())) {
      throw StateError('The owned request reservation changed.');
    }
    final now = DateTime.now().toUtc();
    final completed = owned.finish(
      status,
      at: now,
      returnedSha256: proposal == null
          ? const {}
          : {
              for (final change in proposal.changes)
                change.path: fingerprint(change.after),
            },
      responseModel: proposal?.responseModel,
    );
    final origin = proposal == null
        ? null
        : SessionProposalOrigin(
            reference: SessionProposalRequestReference.fromRequest(completed),
            requestSessionRecord: _requestSessionRecord,
          );
    origin?.requireRequest(completed);
    previous[owned.number - 1] = completed;
    final next = SessionProposalRequestJournal(previous).encode();
    _outcomeWriteAttempted = true;
    await (records as ConditionalRecordStorage).commitRecords(
      expected: {if (proposal != null) ..._returnContext, key: expected},
      updates: {key: next},
      authorize: proposal == null ? () {} : authorizeReturn!,
    );
    _returnedOrigin = origin;
    _owned = null;
  }
}
