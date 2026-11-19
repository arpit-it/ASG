// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import '../models/candidate_verification_run.dart';
import '../models/repair_attempt.dart';
import '../models/model_request_provenance.dart';
import '../models/source_edit_proposal.dart';
import 'record_storage.dart';
import 'repair_request_context.dart';
import 'selected_repair_request_store.dart';
import '../models/selected_repair_request.dart';

/// Reserve before transport. Crashes and cancellations never refund the budget.
class RepairAttemptStore {
  RepairAttemptStore(this.records, this.projectId);
  final RecordStorage records;
  final String projectId;
  String get key => 'studio.repairAttempts.v1.$projectId';
  RepairAttempt? _owned;
  RepairRequestContext? _context;
  SelectedRepairRequest? _origin;
  SelectedRepairRequestReference? _returnedReference;
  SelectedRepairRequestReference? get returnedReference => _returnedReference;
  bool _outcomeWriteAttempted = false;
  bool get outcomeWriteAttempted => _outcomeWriteAttempted;

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
    RepairRequestContext? context,
    SelectedRepairRequestCapture? selectedRequest,
  }) async {
    if (selectedRequest != null &&
        !identical(selectedRequest.context, context)) {
      throw StateError('Selected repair capture does not match its context.');
    }
    if (_owned != null) throw StateError('Repair request already reserved.');
    if (context != null &&
        (!identical(context.records, records) ||
            context.projectId != projectId ||
            !context.matchesFailure(failure))) {
      throw StateError('Repair reservation context identity changed.');
    }
    context?.requireCurrent();
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
    final origin = selectedRequest?.prepare(attempt);
    await _commit(
      expected,
      [...journal.attempts, attempt],
      authorize,
      context: context,
      origin: origin,
      createOrigin: origin != null,
    );
    _origin = origin;
    _returnedReference = null;
    _context = context;
    _outcomeWriteAttempted = false;
    _owned = attempt;
  }

  Future<void> finish(
    RepairAttemptStatus status, {
    SourceEditProposal? proposal,
    void Function()? authorizeReturn,
  }) async {
    final owned = _owned;
    if (owned == null) return;
    if (_outcomeWriteAttempted) {
      throw StateError(
        'Repair outcome persistence is unresolved. Reopen history.',
      );
    }
    if ((status == RepairAttemptStatus.proposed) != (proposal != null) ||
        (status == RepairAttemptStatus.proposed &&
            _context != null &&
            authorizeReturn == null)) {
      throw StateError('A truthful authorized repair outcome is required.');
    }
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
      modelRequest: owned.modelRequest?.withResponseModel(
        proposal?.responseModel,
      ),
      number: owned.number,
      startedAt: owned.startedAt,
      failure: owned.failure,
      status: status,
      proposal: proposal,
    );
    final origin = proposal == null ? null : _origin;
    final reference = origin == null
        ? null
        : SelectedRepairRequestReference.forProposed(
            origin,
            attempts[owned.number - 1],
          );
    // Observing an outcome grants no execution or proposal publication authority.
    _outcomeWriteAttempted = true;
    await _commit(
      expected,
      attempts,
      proposal == null ? () {} : (authorizeReturn ?? () {}),
      context: proposal == null ? null : _context,
      origin: origin,
    );
    _returnedReference = reference;
    _owned = null;
  }

  Future<void> _commit(
    String? expected,
    List<RepairAttempt> attempts,
    void Function() authorize, {
    RepairRequestContext? context,
    SelectedRepairRequest? origin,
    bool createOrigin = false,
  }) async {
    final storage = records;
    if (storage is! ConditionalRecordStorage) {
      throw StateError('Atomic storage is required for repair requests.');
    }
    final raw = jsonEncode(RepairAttemptJournal(attempts).toJson());
    RepairAttemptJournal.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    await storage.commitRecords(
      expected: {
        ...?context?.expected,
        key: expected,
        if (origin != null)
          origin.storageKey: createOrigin ? null : origin.encode(),
      },
      updates: {
        key: raw,
        if (origin != null && createOrigin) origin.storageKey: origin.encode(),
      },
      authorize: () {
        authorize();
        context?.requireCurrent();
      },
    );
  }
}
