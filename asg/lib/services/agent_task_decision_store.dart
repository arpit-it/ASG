// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/agent_execution_checkpoint.dart';
import '../models/agent_session.dart';
import '../models/agent_session_publication.dart';
import '../models/agent_task_decision.dart';
import '../models/candidate_verification_run.dart';
import '../models/candidate_reopen_context.dart';
import '../models/prerequisite_preparation_evidence.dart';
import '../models/project.dart';
import '../models/requirement_check_report.dart';
import 'agent_session_publication_store.dart';
import 'published_task_evidence_store.dart';
import 'record_storage.dart';
import 'requirement_check_report_store.dart';
import 'requirements_store.dart';

bool _same(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);
String _hash(Object value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();

/// Private read-set capture. Every repeated read and the final set must agree.
final class _DecisionReads implements RecordStorage {
  _DecisionReads(this.source);
  final RecordStorage source;
  final Map<String, String?> expected = {};
  @override
  String? getString(String key) {
    final value = source.getString(key);
    if (expected.containsKey(key) && expected[key] != value) {
      throw StateError('Evidence changed.');
    }
    expected[key] = value;
    return value;
  }

  void requireUnchanged() {
    if (expected.entries.any((e) => source.getString(e.key) != e.value)) {
      throw StateError('Evidence changed.');
    }
  }

  @override
  Future<bool> setString(String key, String value) =>
      throw StateError('Selection is read-only.');
}

/// Frozen confirmation selection, including the exact displayed record read-set.
final class AgentTaskDecisionSelection {
  AgentTaskDecisionSelection._(
    this._owner,
    this.evidence,
    Map<String, String?> expected,
  ) : _expected = Map.unmodifiable(expected);
  final Object _owner;
  final Map<String, String?> _expected;
  final AgentTaskDecisionEvidence evidence;
}

/// The only writer publishes one expected-absent decision after explicit consent.
/// No host, runner, model, file inspection or board/session mutation is involved.
class AgentTaskDecisionStore {
  AgentTaskDecisionStore(this.records, this.project, {DateTime Function()? now})
    : now = now ?? DateTime.now;
  final RecordStorage records;
  final StudioProject project;
  final DateTime Function() now;
  final Object _owner = Object();

  static AgentTaskDecision decode(String key, String raw) {
    final value = AgentTaskDecision.decode(raw);
    if (value.storageKey != key || jsonEncode(value.toJson()) != raw) {
      throw const FormatException('Decision identity changed.');
    }
    return value;
  }

  AgentTaskDecisionSelection select(
    AgentSession session,
    int number, {
    Map<String, int> prerequisites = const {},
  }) {
    if (session.cancellationRequested) {
      throw StateError('Withdrawn sessions cannot record new decisions.');
    }
    final reads = _DecisionReads(records);
    // Existing read-only applicability checks bind current working, Plan and graph.
    PublishedTaskEvidenceStore(reads, project).load(session, number);
    final publication = AgentTaskDecisionHistoryStore(
      reads,
      project.id,
    )._publication(reads, session, number);
    final task = session.tasks.items.singleWhere(
      (t) => t.id == publication.reference.boardTaskId,
    );
    if (prerequisites.length != task.dependencies.length ||
        task.dependencies.any((id) => !prerequisites.containsKey(id))) {
      throw StateError('Select one retained decision for each prerequisite.');
    }
    final board = RequirementsStore(reads).load(project.id);
    final refs = <AgentTaskDecisionReference>[];
    final visited = <int, AgentTaskDecision>{};
    for (final id in task.dependencies) {
      final decision = AgentTaskDecisionHistoryStore(
        reads,
        project.id,
      )._read(reads, session, prerequisites[id]!, visited);
      if (decision == null ||
          decision.evidence.publication.reference.boardTaskId != id ||
          !_same(
            decision.evidence.requirement.toJson(),
            board.requirements
                .singleWhere((r) => r.id == decision.evidence.requirement.id)
                .toJson(),
          )) {
        throw StateError(
          'Prerequisite decision does not match the frozen contract.',
        );
      }
      refs.add(
        AgentTaskDecisionReference(
          id,
          prerequisites[id]!,
          decision.fingerprint,
        ),
      );
    }
    final report = RequirementCheckReportStore(reads).load(project);
    final requirement = report.results
        .singleWhere((r) => r.requirement.id == task.requirementId)
        .requirement;
    final evidence = AgentTaskDecisionEvidence.capture(
      publication: publication,
      report: report,
      requirement: requirement,
      prerequisites: refs,
    );
    final target = AgentTaskDecision.keyFor(
      project.id,
      session.sessionId,
      number,
    );
    if (reads.getString(target) != null) {
      throw StateError('A decision is already retained for this publication.');
    }
    reads.requireUnchanged();
    return AgentTaskDecisionSelection._(_owner, evidence, reads.expected);
  }

  Future<AgentTaskDecision> confirm(
    AgentTaskDecisionSelection selection, {
    required bool consent,
    required bool Function() authorized,
  }) async {
    final storage = records;
    if (storage is! ConditionalRecordStorage ||
        !identical(selection._owner, _owner) ||
        !consent ||
        !authorized()) {
      throw StateError(
        'Explicit current confirmation and transactional storage are required.',
      );
    }
    final decision = AgentTaskDecision.confirm(
      selection.evidence,
      now(),
      consent: consent,
    );
    final encoded = jsonEncode(decision.toJson());
    // A repeated confirmation never rewrites time or evidence. No new write occurs.
    final existing = records.getString(decision.storageKey);
    if (existing != null) {
      final retained = decode(decision.storageKey, existing);
      if (retained.evidence.fingerprint != selection.evidence.fingerprint) {
        throw StateError('A conflicting decision is retained.');
      }
      return retained;
    }
    await storage.commitRecords(
      expected: selection._expected,
      updates: {decision.storageKey: encoded},
      authorize: () {
        if (!authorized()) {
          throw StateError('Confirmation was withdrawn before saving.');
        }
      },
    );
    return decision;
  }

  /// Historical loading shares the project-ID-only proof reader.
  AgentTaskDecision? load(AgentSession session, int number) =>
      AgentTaskDecisionHistoryStore(records, project.id).load(session, number);
}

/// Strict retained decision history, independent of current project inputs.
/// Reads only; missing records are never backfilled and no host is constructed.
class AgentTaskDecisionHistoryStore {
  AgentTaskDecisionHistoryStore(this.records, this.projectId);
  final RecordStorage records;
  final String projectId;

  /// Historical loading never consults current working/Plan/check observations.
  AgentTaskDecision? load(AgentSession session, int number) {
    final reads = _DecisionReads(records);
    final raw = reads.getString(session.storageKey);
    if (session.projectId != projectId ||
        raw == null ||
        utf8.encode(raw).length > AgentSession.maxEncodedBytes ||
        raw != jsonEncode(session.toJson()) ||
        jsonEncode(AgentSession.fromJson(jsonDecode(raw)).toJson()) != raw ||
        session.dispatches.where((ref) => ref.runNumber == number).length !=
            1) {
      throw const FormatException('Decision session or reference changed.');
    }
    final value = _read(reads, session, number, {});
    reads.requireUnchanged();
    return value;
  }

  AgentTaskDecision? _read(
    _DecisionReads reads,
    AgentSession session,
    int number,
    Map<int, AgentTaskDecision> visited,
  ) {
    if (visited.containsKey(number)) return visited[number];
    if (visited.length >= AgentSession.maxDispatches) {
      throw const FormatException('Decision history exceeds its bound.');
    }
    final raw = reads.getString(
      AgentTaskDecision.keyFor(projectId, session.sessionId, number),
    );
    if (raw == null) return null;
    final decision = AgentTaskDecisionStore.decode(
      AgentTaskDecision.keyFor(projectId, session.sessionId, number),
      raw,
    );
    final publication = _publication(reads, session, number);
    if (!_same(publication.toJson(), decision.evidence.publication.toJson())) {
      throw const FormatException('Decision publication changed.');
    }
    final run = _run(reads, number);
    final identity = RequirementRunIdentity(
      sources: run.snapshot.sources,
      currentInputs: run.snapshot.sources,
      approvalSha256: _hash(run.snapshot.approval!.toJson()),
    );
    if (!_same(identity.toJson(), decision.evidence.toJson()['identity'])) {
      throw const FormatException('Decision source/input identity changed.');
    }
    visited[number] = decision;
    for (final ref in decision.evidence.prerequisites) {
      final prerequisite = _read(reads, session, ref.runNumber, visited);
      if (prerequisite == null ||
          prerequisite.fingerprint != ref.sha256 ||
          prerequisite.evidence.publication.reference.boardTaskId !=
              ref.taskId) {
        throw const FormatException(
          'Retained prerequisite proof is unavailable.',
        );
      }
    }
    return decision;
  }

  CandidateVerificationRun _run(RecordStorage reads, int number) =>
      CandidateVerificationJournal.fromJson(
        jsonDecode(reads.getString('studio.candidateChecks.v1.$projectId')!)
            as Map<String, dynamic>,
      ).runs.singleWhere((run) => run.number == number);

  AgentSessionPublication _publication(
    RecordStorage reads,
    AgentSession session,
    int number,
  ) {
    if (session.projectId != projectId) {
      throw const FormatException('Foreign decision session.');
    }
    final run = _run(reads, number);
    final ref = session.dispatches.singleWhere(
      (ref) => ref.runNumber == number,
    );
    final execution = AgentExecutionCheckpoint.fromJson(
      jsonDecode(
        reads.getString(
          'studio.agentExecution.v1.${ref.dispatchId.split(':').first}',
        )!,
      ),
    );
    final value = AgentSessionPublicationStore(
      reads,
      projectId,
    ).load(session: session, run: run, execution: execution);
    if (value == null) {
      throw const FormatException('Retained publication is unavailable.');
    }
    return value;
  }
}

/// Historical preparation facts for explicitly retained prerequisite references.
/// No latest-candidate/current-approval reader, host or writer is constructed.
class AgentPrerequisitePreparationStore {
  AgentPrerequisitePreparationStore(this.records, this.projectId);
  final RecordStorage records;
  final String projectId;

  PrerequisitePreparationReview? load(AgentSession session, int number) {
    final reads = _DecisionReads(records);
    final history = AgentTaskDecisionHistoryStore(reads, projectId);
    final decision = history.load(session, number);
    if (decision == null) {
      reads.requireUnchanged();
      return null;
    }
    final refs = decision.evidence.prerequisites;
    CandidateReopenContext? context;
    if (refs.isNotEmpty) {
      try {
        final key = '${CandidateReopenContext.prefix}$projectId.$number';
        final raw = reads.getString(key);
        if (raw == null) throw const FormatException();
        final value = CandidateReopenContext.decode(raw);
        final run = history._run(reads, number);
        final publication = decision.evidence.publication;
        value.requireRun(run);
        if (value.storageKey != key ||
            raw != jsonEncode(value.toJson()) ||
            !_same(value.session.toJson(), publication.session.toJson()) ||
            value.basis.workingSha256 != publication.originalWorkingSha256) {
          throw const FormatException('Preparation context changed.');
        }
        context = value;
      } catch (_) {
        // Optional context failure cannot erase the retained decision.
      }
    }
    final edges = <PrerequisitePreparationEvidence>[];
    for (final ref in refs) {
      var state = PrerequisitePreparationState.unavailable;
      try {
        if (context != null) {
          final prior = history._read(reads, session, ref.runNumber, {});
          final run = history._run(reads, ref.runNumber);
          if (prior == null ||
              prior.fingerprint != ref.sha256 ||
              prior.evidence.publication.reference.boardTaskId != ref.taskId) {
            throw const FormatException('Prerequisite identity changed.');
          }
          final basis = context.basis;
          final sources = run.snapshot.sources;
          final reviewed = basis.sourceBase.sources;
          // Raw working digests include build-history metadata, which typed
          // snapshots intentionally omit. Preserve the recorded digest link and
          // independently compare the validated typed snapshots; never hash a
          // projection and call it the original working record.
          final sameWorking = _same(
            basis.working.toJson(),
            run.snapshot.toJson(),
          );
          final sameSources =
              sources.length == reviewed.length &&
              sources.entries.every((e) => reviewed[e.key] == e.value);
          state =
              basis.workingSha256 ==
                      prior.evidence.publication.publishedWorkingSha256 &&
                  sameWorking &&
                  sameSources
              ? PrerequisitePreparationState.directRecordedLink
              : PrerequisitePreparationState.noDirectMatch;
        }
      } catch (_) {
        // Preserve other independently proven edges and the historical decision.
      }
      edges.add(PrerequisitePreparationEvidence(ref, state));
    }
    reads.requireUnchanged();
    return PrerequisitePreparationReview(
      decisionSha256: decision.fingerprint,
      runNumber: number,
      prerequisites: edges,
    );
  }
}
