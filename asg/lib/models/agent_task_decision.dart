// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'agent_session_publication.dart';
import 'named_check_observation.dart';
import 'requirement_check_report.dart';
import 'requirements_board.dart';
import 'structured_proposal_json.dart';

String _hash(Object value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();
bool _same(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);
void _keys(Map<String, dynamic> value, Set<String> keys) {
  if (value.length != keys.length || !keys.every(value.containsKey)) {
    throw const FormatException('Invalid decision fields.');
  }
}

/// An explicit historical prerequisite reference, never scheduler authority.
final class AgentTaskDecisionReference {
  const AgentTaskDecisionReference(this.taskId, this.runNumber, this.sha256);
  final String taskId, sha256;
  final int runNumber;
  Map<String, Object> toJson() => {
    'taskId': taskId,
    'runNumber': runNumber,
    'sha256': sha256,
  };
  factory AgentTaskDecisionReference.fromJson(Map<String, dynamic> value) {
    _keys(value, {'taskId', 'runNumber', 'sha256'});
    if (value['taskId'] is! String ||
        !RegExp(r'^[A-Za-z][A-Za-z0-9_-]{0,39}$')
            .hasMatch(value['taskId'] as String) ||
        value['runNumber'] is! int ||
        (value['runNumber'] as int) < 1 ||
        value['sha256'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['sha256'] as String)) {
      throw const FormatException('Invalid prerequisite decision.');
    }
    return AgentTaskDecisionReference(
      value['taskId'] as String,
      value['runNumber'] as int,
      value['sha256'] as String,
    );
  }
}

/// Frozen typed proof. No display label is parsed into a decision predicate.
final class AgentTaskDecisionEvidence {
  AgentTaskDecisionEvidence._(this._encoded);
  final String _encoded;
  Map<String, dynamic> toJson() => jsonDecode(_encoded) as Map<String, dynamic>;
  AgentSessionPublication get publication =>
      AgentSessionPublication.fromJson(toJson()['publication']);
  ProjectRequirement get requirement => ProjectRequirement.fromJson(
    toJson()['requirement'] as Map<String, dynamic>,
  );
  List<AgentTaskDecisionReference> get prerequisites => List.unmodifiable([
    for (final value in toJson()['prerequisites'] as List)
      AgentTaskDecisionReference.fromJson(value as Map<String, dynamic>),
  ]);
  List<NamedCheckObservation> get observations => List.unmodifiable([
    for (final value in toJson()['observations'] as List)
      NamedCheckObservation.fromJson(value as Map<String, dynamic>),
  ]);
  String get fingerprint => _hash(toJson());

  factory AgentTaskDecisionEvidence.capture({
    required AgentSessionPublication publication,
    required RequirementCheckReport report,
    required ProjectRequirement requirement,
    required List<AgentTaskDecisionReference> prerequisites,
  }) {
    if (!report.requirementVerifiedAgainstChecks(requirement)) {
      throw const FormatException(
        'Every authored named-test contract must pass.',
      );
    }
    final ids = requirement.criteria.expand((c) => c.checkIds).toSet();
    return AgentTaskDecisionEvidence.fromJson({
      'publication': publication.toJson(),
      'requirement': requirement.toJson(),
      'identity': report.revisionIdentity!.toJson(),
      'observations': [
        for (final id in ids)
          report.namedObservationFor(requirement.id, id)!.toJson(),
      ],
      'prerequisites': prerequisites.map((p) => p.toJson()).toList(),
    });
  }

  factory AgentTaskDecisionEvidence.fromJson(Object? raw) {
    try {
      if (raw is! Map<String, dynamic>) throw const FormatException();
      _keys(raw, {
        'publication',
        'requirement',
        'identity',
        'observations',
        'prerequisites',
      });
      final publication = AgentSessionPublication.fromJson(raw['publication']);
      final requirement = ProjectRequirement.fromJson(
        raw['requirement'] as Map<String, dynamic>,
      );
      RequirementsBoard(requirements: [requirement]).validate();
      if (!_same(requirement.toJson(), raw['requirement'])) {
        throw const FormatException();
      }
      final task = publication.session.tasks.items.singleWhere(
        (t) => t.id == publication.reference.boardTaskId,
      );
      if (task.requirementId != requirement.id ||
          requirement.criteria.isEmpty ||
          requirement.criteria.any(
            (c) =>
                c.verificationRule !=
                    CriterionVerificationRule.allMappedNamedTests ||
                c.checkIds.isEmpty,
          )) {
        throw const FormatException();
      }
      final identity = raw['identity'] as Map<String, dynamic>;
      _keys(identity, {
        'schema',
        'scope',
        'savedRunSha256',
        'savedSourceSha256',
        'savedInputSha256',
        'savedApprovalSha256',
        'currentInputSha256',
      });
      for (final key in [
        'savedRunSha256',
        'savedSourceSha256',
        'savedInputSha256',
        'savedApprovalSha256',
        'currentInputSha256',
      ]) {
        if (identity[key] is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(identity[key] as String)) {
          throw const FormatException();
        }
      }
      if (identity['schema'] is! int ||
          identity['schema'] != 1 ||
          identity['scope'] !=
              'Saved content identity only; not a direct check result or live artifact observation.' ||
          identity['savedInputSha256'] != identity['currentInputSha256'] ||
          identity['savedApprovalSha256'] !=
              _hash(publication.session.approval.toJson()) ||
          identity['savedRunSha256'] !=
              _hash({
                'schema': 1,
                'sourceSha256': identity['savedSourceSha256'],
                'inputSha256': identity['savedInputSha256'],
                'approvalSha256': identity['savedApprovalSha256'],
              })) {
        throw const FormatException();
      }
      final ids = requirement.criteria.expand((c) => c.checkIds).toSet();
      final observations = (raw['observations'] as List)
          .map((v) => NamedCheckObservation.fromJson(v as Map<String, dynamic>))
          .toList();
      if (observations.length != ids.length ||
          observations.map((v) => v.checkId).toSet().length != ids.length) {
        throw const FormatException();
      }
      for (final id in ids) {
        final check = requirement.checks.singleWhere((c) => c.id == id);
        final observation = observations.singleWhere((v) => v.checkId == id);
        if (check.type != AcceptanceCheckType.automated ||
            check.target == null ||
            observation.requirementId != requirement.id ||
            observation.requirementSha256 !=
                RequirementAcceptanceEvidence(requirement).requirementSha256 ||
            observation.runSha256 != identity['savedRunSha256'] ||
            !_same(
              observation.result.target.toJson(),
              check.target!.toJson(),
            ) ||
            !observation.result.passed) {
          throw const FormatException();
        }
      }
      final refs = (raw['prerequisites'] as List)
          .map(
            (v) =>
                AgentTaskDecisionReference.fromJson(v as Map<String, dynamic>),
          )
          .toList();
      if (refs.length != task.dependencies.length ||
          refs.map((r) => r.taskId).toSet().length != refs.length ||
          refs.any(
            (r) =>
                !task.dependencies.contains(r.taskId) ||
                r.runNumber >= publication.runNumber,
          )) {
        throw const FormatException();
      }
      final canonical = {
        'publication': publication.toJson(),
        'requirement': requirement.toJson(),
        'identity': identity,
        'observations': observations.map((v) => v.toJson()).toList(),
        'prerequisites': refs.map((v) => v.toJson()).toList(),
      };
      if (!_same(canonical, raw)) throw const FormatException();
      final encoded = jsonEncode(canonical);
      if (utf8.encode(encoded).length >
          AgentTaskDecision.maxEncodedBytes - 1024) {
        throw const FormatException();
      }
      return AgentTaskDecisionEvidence._(encoded);
    } catch (_) {
      throw const FormatException('Invalid frozen authored-check evidence.');
    }
  }
}

/// A user-confirmed historical authored-check decision. No board or execution state.
final class AgentTaskDecision {
  AgentTaskDecision._(this._encoded);
  final String _encoded;
  static const prefix = 'studio.agentTaskDecision.v1.';
  static const maxEncodedBytes = 1024 * 1024;
  Map<String, dynamic> toJson() => jsonDecode(_encoded) as Map<String, dynamic>;
  AgentTaskDecisionEvidence get evidence =>
      AgentTaskDecisionEvidence.fromJson(toJson()['evidence']);
  DateTime get confirmedAt => DateTime.parse(toJson()['confirmedAt'] as String);
  String get storageKey => keyFor(
    evidence.publication.session.projectId,
    evidence.publication.session.sessionId,
    evidence.publication.runNumber,
  );
  String get fingerprint => _hash(toJson());
  static String keyFor(String projectId, String sessionId, int runNumber) =>
      '$prefix$projectId.$sessionId.$runNumber';
  factory AgentTaskDecision.confirm(
    AgentTaskDecisionEvidence evidence,
    DateTime at, {
    required bool consent,
  }) {
    if (!consent) throw const FormatException('Explicit consent is required.');
    return AgentTaskDecision.fromJson({
      'version': 1,
      'mode': 'completedAgainstAuthoredChecks',
      'confirmedAt': at.toUtc().toIso8601String(),
      'evidence': evidence.toJson(),
    });
  }
  factory AgentTaskDecision.decode(String raw) {
    if (raw.length > maxEncodedBytes ||
        utf8.encode(raw).length > maxEncodedBytes) {
      throw const FormatException('Decision exceeds its bound.');
    }
    rejectDuplicateJsonMembers(raw);
    return AgentTaskDecision.fromJson(jsonDecode(raw));
  }
  factory AgentTaskDecision.fromJson(Object? raw) {
    try {
      if (raw is! Map<String, dynamic>) throw const FormatException();
      _keys(raw, {'version', 'mode', 'confirmedAt', 'evidence'});
      if (raw['version'] is! int ||
          raw['version'] != 1 ||
          raw['mode'] != 'completedAgainstAuthoredChecks' ||
          raw['confirmedAt'] is! String) {
        throw const FormatException();
      }
      final at = DateTime.parse(raw['confirmedAt'] as String);
      if (!at.isUtc || at.toIso8601String() != raw['confirmedAt']) {
        throw const FormatException();
      }
      final evidence = AgentTaskDecisionEvidence.fromJson(raw['evidence']);
      final encoded = jsonEncode({
        'version': 1,
        'mode': 'completedAgainstAuthoredChecks',
        'confirmedAt': at.toIso8601String(),
        'evidence': evidence.toJson(),
      });
      if (utf8.encode(encoded).length > maxEncodedBytes) {
        throw const FormatException();
      }
      return AgentTaskDecision._(encoded);
    } catch (_) {
      throw const FormatException(
        'Saved authored-check decision is unreadable.',
      );
    }
  }
}
