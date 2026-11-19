// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'agent_session.dart';
import 'approved_source_proposal.dart';
import 'candidate_verification_run.dart';
import 'model_request_provenance.dart';
import 'plan_approval.dart';
import 'source_edit_proposal.dart';
import 'source_generation.dart';
import 'structured_proposal_json.dart';

bool _same(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);
String _hash(String value) => sha256.convert(utf8.encode(value)).toString();
void _shape(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !keys.every(value.containsKey)) {
    throw const FormatException('Invalid candidate reopen fields.');
  }
}

GeneratedProject _snapshot(Object? value) {
  if (value is! Map<String, dynamic>) throw const FormatException();
  final result = GeneratedProject.fromJson(value);
  _shape(value, result.toJson().keys.toSet());
  if (result.sources.isEmpty ||
      result.sources.length > 2048 ||
      result.sources.entries.any(
        (entry) =>
            entry.key.length > 256 ||
            entry.key.startsWith('/') ||
            entry.key.contains('\\') ||
            entry.key
                .split('/')
                .any((part) => part.isEmpty || part == '.' || part == '..') ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(entry.value),
      )) {
    throw const FormatException('Invalid reopen source identity.');
  }
  return result;
}

Map<String, Object> _stable(GeneratedProject value) => Map.of(value.toJson())
  ..removeWhere(
    (key, _) => const {
      'steps',
      'outputs',
      'resolution',
      'phase',
      'error',
      'pendingOperation',
      'failedOperation',
      'checkpointVersion',
    }.contains(key),
  );

/// Frozen preparation evidence only; it never grants permission to execute.
/// Encoded storage prevents callers mutating nested legacy snapshot maps.
final class CandidateReopenBasis {
  CandidateReopenBasis._(this._encoded);
  static const maxEncodedBytes = 2 * 1024 * 1024;
  final String _encoded;
  Map<String, dynamic> toJson() => jsonDecode(_encoded) as Map<String, dynamic>;
  String get projectId => toJson()['projectId'] as String;
  String get workingSha256 => toJson()['workingSha256'] as String;
  GeneratedProject get working => _snapshot(toJson()['working']);
  GeneratedProject get sourceBase => _snapshot(toJson()['sourceBase']);
  GeneratedProject get prepared => _snapshot(toJson()['prepared']);
  ApprovedSourceProposal get evidence =>
      _evidence(toJson()['evidence'], projectId);

  factory CandidateReopenBasis.capture({
    required String projectId,
    required String workingRecord,
    required GeneratedProject working,
    required GeneratedProject sourceBase,
    required GeneratedProject prepared,
    required ApprovedSourceProposal evidence,
  }) {
    if (evidence.projectId != projectId || evidence.repairRun != null) {
      throw const FormatException('Expected exact prepared proposal evidence.');
    }
    if (!_same(
      GeneratedProject.fromJson(jsonDecode(workingRecord)).toJson(),
      working.toJson(),
    )) {
      throw const FormatException('Original working identity changed.');
    }
    return CandidateReopenBasis.fromJson({
      'version': 1,
      'projectId': projectId,
      'workingSha256': _hash(workingRecord),
      'working': working.toJson(),
      'sourceBase': sourceBase.toJson(),
      'prepared': prepared.toJson(),
      'evidence': {
        'boardTaskId': evidence.boardTaskId,
        'approval': evidence.approval.toJson(),
        'proposal': {
          'summary': evidence.proposal.summary,
          'changes': [
            for (final change in evidence.proposal.changes)
              {
                'path': change.path,
                'before': change.before,
                'after': change.after,
              },
          ],
        },
        'responseModel': evidence.proposal.responseModel,
        'modelRequest': evidence.modelRequest?.toJson(),
      },
    });
  }

  factory CandidateReopenBasis.fromJson(Object? value) {
    try {
      return CandidateReopenBasis._parse(value);
    } catch (_) {
      throw const FormatException('Invalid candidate reopen context.');
    }
  }

  static CandidateReopenBasis _parse(Object? value) {
    final encoded = jsonEncode(value);
    if (encoded.length > maxEncodedBytes ||
        utf8.encode(encoded).length > maxEncodedBytes) {
      throw const FormatException(
        'Candidate reopen context exceeds its bound.',
      );
    }
    _shape(value, {
      'version',
      'projectId',
      'workingSha256',
      'working',
      'sourceBase',
      'prepared',
      'evidence',
    });
    final data = value as Map<String, dynamic>;
    if (data['version'] is! int ||
        data['version'] != 1 ||
        data['projectId'] is! String ||
        !RegExp(r'^[a-zA-Z0-9_-]{1,128}$')
            .hasMatch(data['projectId'] as String) ||
        data['workingSha256'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(data['workingSha256'] as String)) {
      throw const FormatException('Invalid candidate reopen identity.');
    }
    _snapshot(data['working']);
    final base = _snapshot(data['sourceBase']);
    final prepared = _snapshot(data['prepared']);
    final evidence = _evidence(data['evidence'], data['projectId'] as String);
    if (!prepared.confined ||
        prepared.directory == base.directory ||
        prepared.directory == _snapshot(data['working']).directory ||
        prepared.sdk != base.sdk ||
        prepared.python != base.python ||
        prepared.approval?.matches(evidence.approval) != true ||
        prepared.tasks?.any(
              (task) => task.boardTaskId == evidence.boardTaskId,
            ) !=
            true ||
        !_same(
          prepared.sourceRequest?.toJson(),
          evidence.modelRequest?.toJson(),
        ) ||
        prepared.sources.length != base.sources.length ||
        !base.sources.keys.every(prepared.sources.containsKey)) {
      throw const FormatException('Prepared candidate identity changed.');
    }
    final working = _snapshot(data['working']);
    if (const ['assets/app.json', 'asg_project.json'].any(
      (key) =>
          base.sources[key] == null ||
          base.sources[key] != working.sources[key],
    )) {
      throw const FormatException('Original project input identity changed.');
    }
    final changes = {
      for (final change in evidence.proposal.changes) change.path: change,
    };
    for (final entry in base.sources.entries) {
      final change = changes[entry.key];
      if (change == null
          ? prepared.sources[entry.key] != entry.value
          : _hash(change.before) != entry.value ||
                _hash(change.after) != prepared.sources[entry.key]) {
        throw const FormatException('Reviewed source identity changed.');
      }
    }
    if (!changes.keys.every(base.sources.containsKey)) {
      throw const FormatException(
        'Reviewed source is not in the original base.',
      );
    }
    return CandidateReopenBasis._(encoded);
  }

  static ApprovedSourceProposal _evidence(Object? value, String projectId) {
    _shape(value, {
      'boardTaskId',
      'approval',
      'proposal',
      'responseModel',
      'modelRequest',
    });
    final data = value as Map<String, dynamic>;
    final task = data['boardTaskId'];
    final response = data['responseModel'];
    if (task is! String ||
        !RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(task) ||
        (response != null &&
            (response is! String ||
                response.trim().isEmpty ||
                response.length > 4096 ||
                RegExp(r'[\x00-\x1f\x7f]').hasMatch(response)))) {
      throw const FormatException('Invalid reviewed candidate provenance.');
    }
    final approval = PlanApproval.fromJson(
      Map<String, dynamic>.from(data['approval'] as Map),
    );
    _shape(data['approval'], approval.toJson().keys.toSet());
    final proposalData = data['proposal'];
    if (proposalData is! Map<String, dynamic> ||
        proposalData['changes'] is! List) {
      throw const FormatException();
    }
    final originals = <String, String>{};
    for (final raw in proposalData['changes'] as List) {
      if (raw is! Map || raw['path'] is! String || raw['before'] is! String) {
        throw const FormatException();
      }
      originals[raw['path'] as String] = raw['before'] as String;
    }
    final proposal = SourceEditProposal.parse(
      proposalData,
      originals: originals,
      responseModel: response as String?,
    );
    if (proposal.summary != proposalData['summary']) {
      throw const FormatException();
    }
    final request = data['modelRequest'] == null
        ? null
        : ModelRequestProvenance.fromJson(data['modelRequest']);
    request?.validate();
    if (request != null && request.responseModel != proposal.responseModel) {
      throw const FormatException('Response model provenance changed.');
    }
    if (request != null &&
        request.outputTokens != ModelRequestProvenance.sourceOutputTokens) {
      throw const FormatException();
    }
    return ApprovedSourceProposal(
      projectId: projectId,
      boardTaskId: task,
      approval: approval,
      proposal: proposal,
      modelRequest: request,
    );
  }

  bool matchesCandidate(GeneratedProject value) =>
      _same(_stable(prepared), _stable(value));
  bool matchesWorkingRecord(String raw) => _hash(raw) == workingSha256;
}

/// One immutable admitted context. This is not a tool authorization or receipt.
final class CandidateReopenContext {
  CandidateReopenContext._(this._encoded);
  static const prefix = 'studio.candidateReopen.v1.';
  static const maxEncodedBytes =
      CandidateReopenBasis.maxEncodedBytes +
      AgentSession.maxEncodedBytes +
      8192;
  final String _encoded;
  Map<String, dynamic> toJson() => jsonDecode(_encoded) as Map<String, dynamic>;
  CandidateReopenBasis get basis =>
      CandidateReopenBasis.fromJson(toJson()['basis']);
  AgentSession get session => AgentSession.fromJson(toJson()['session']);
  int get runNumber => toJson()['runNumber'] as int;
  String get dispatchId => toJson()['dispatchId'] as String;
  DateTime get startedAt => DateTime.parse(toJson()['startedAt'] as String);
  String get storageKey => '$prefix${basis.projectId}.$runNumber';

  factory CandidateReopenContext.bind(
    CandidateReopenBasis basis,
    AgentSession session,
    CandidateVerificationRun run,
  ) {
    final result = CandidateReopenContext.fromJson({
      'version': 1,
      'basis': basis.toJson(),
      'session': session.toJson(),
      'runNumber': run.number,
      'dispatchId': run.dispatchId,
      'startedAt': run.startedAt.toUtc().toIso8601String(),
    });
    result.requireRun(run);
    return result;
  }

  factory CandidateReopenContext.decode(String raw) {
    if (raw.length > maxEncodedBytes ||
        utf8.encode(raw).length > maxEncodedBytes) {
      throw const FormatException(
        'Candidate reopen context exceeds its bound.',
      );
    }
    rejectDuplicateJsonMembers(raw);
    return CandidateReopenContext.fromJson(jsonDecode(raw));
  }

  factory CandidateReopenContext.fromJson(Object? value) {
    try {
      return CandidateReopenContext._parse(value);
    } catch (_) {
      throw const FormatException('Invalid candidate reopen context.');
    }
  }

  static CandidateReopenContext _parse(Object? value) {
    final encoded = jsonEncode(value);
    if (encoded.length > maxEncodedBytes ||
        utf8.encode(encoded).length > maxEncodedBytes) {
      throw const FormatException(
        'Candidate reopen context exceeds its bound.',
      );
    }
    _shape(value, {
      'version',
      'basis',
      'session',
      'runNumber',
      'dispatchId',
      'startedAt',
    });
    final data = value as Map<String, dynamic>;
    if (data['version'] is! int ||
        data['version'] != 1 ||
        data['runNumber'] is! int ||
        (data['runNumber'] as int) < 1 ||
        data['dispatchId'] is! String) {
      throw const FormatException();
    }
    final date = data['startedAt'];
    if (date is! String ||
        date.length > 40 ||
        DateTime.tryParse(date)?.isUtc != true ||
        DateTime.parse(date).toIso8601String() != date) {
      throw const FormatException('Invalid candidate admission time.');
    }
    final basis = CandidateReopenBasis.fromJson(data['basis']);
    final session = AgentSession.fromJson(data['session']);
    if (session.cancellationRequested ||
        session.projectId != basis.projectId ||
        !session.approval.matches(basis.evidence.approval) ||
        session.dispatches.isEmpty ||
        session.dispatches.last.runNumber != data['runNumber'] ||
        session.dispatches.last.dispatchId != data['dispatchId'] ||
        session.dispatches.last.boardTaskId != basis.evidence.boardTaskId) {
      throw const FormatException('Candidate reopen admission mismatch.');
    }
    return CandidateReopenContext._(encoded);
  }

  void requireRun(CandidateVerificationRun run) {
    if (run.startedAt.toUtc() != startedAt ||
        run.number != runNumber ||
        run.dispatchId != dispatchId ||
        !basis.matchesCandidate(run.snapshot)) {
      throw const FormatException('Candidate reopen run changed.');
    }
  }
}
