// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import '../models/candidate_verification_run.dart';
import '../models/repair_attempt.dart';
import '../models/model_request_provenance.dart';
import '../models/source_edit_proposal.dart';
import 'record_storage.dart';

/// Reserve before transport. Crashes and cancellations never refund the budget.
class RepairAttemptStore {
  RepairAttemptStore(this.records, this.projectId);
  final RecordStorage records;
  final String projectId;
  String get key => 'studio.repairAttempts.v1.$projectId';
  RepairAttempt? _owned;

  RepairAttemptJournal load() {
    final raw = records.getString(key);
    return raw == null
        ? RepairAttemptJournal([])
        : RepairAttemptJournal.fromJson(
            jsonDecode(raw) as Map<String, dynamic>,
          );
  }

  Future<void> reserve(
    CandidateVerificationRun failure,
    void Function() authorize, {
    ModelRequestProvenance? modelRequest,
  }) async {
    if (_owned != null) throw StateError('Repair request already reserved.');
    final expected = records.getString(key);
    final journal = load();
    final category = failure.snapshot.steps.last.operation;
    final used = journal.attempts
        .where(
          (a) =>
              a.category == category &&
              a.failure.snapshot.approval!.matches(failure.snapshot.approval!),
        )
        .length;
    if (used >= 3) {
      throw StateError(
        'Repair budget exhausted: $category has used three requests for this approval. Inspect the retained evidence.',
      );
    }
    final attempt = RepairAttempt(
      modelRequest: modelRequest,
      number: journal.attempts.length + 1,
      startedAt: DateTime.now().toUtc(),
      failure: failure,
      status: RepairAttemptStatus.reserved,
    );
    await _commit(expected, [...journal.attempts, attempt], authorize);
    _owned = attempt;
  }

  Future<void> finish(
    RepairAttemptStatus status, {
    SourceEditProposal? proposal,
  }) async {
    final owned = _owned;
    if (owned == null) return;
    if (status == RepairAttemptStatus.reserved) {
      throw StateError('Terminal status required.');
    }
    final expected = records.getString(key);
    final attempts = load().attempts.toList();
    if (attempts.length < owned.number ||
        jsonEncode(attempts[owned.number - 1].toJson()) !=
            jsonEncode(owned.toJson())) {
      throw StateError('Saved repair request changed. Reopen history.');
    }
    attempts[owned.number - 1] = RepairAttempt(
      modelRequest: owned.modelRequest,
      number: owned.number,
      startedAt: owned.startedAt,
      failure: owned.failure,
      status: status,
      proposal: proposal,
    );
    // Observing an outcome grants no execution or proposal publication authority.
    await _commit(expected, attempts, () {});
    _owned = null;
  }

  Future<void> _commit(
    String? expected,
    List<RepairAttempt> attempts,
    void Function() authorize,
  ) async {
    final storage = records;
    if (storage is! ConditionalRecordStorage) {
      throw StateError('Atomic storage is required for repair requests.');
    }
    final raw = jsonEncode(RepairAttemptJournal(attempts).toJson());
    RepairAttemptJournal.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    await storage.commitRecords(
      expected: {key: expected},
      updates: {key: raw},
      authorize: authorize,
    );
  }
}
