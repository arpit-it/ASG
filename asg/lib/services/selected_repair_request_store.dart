// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import '../models/model_request_provenance.dart';
import '../models/repair_attempt.dart';
import '../models/selected_repair_request.dart';
import 'repair_request_context.dart';
import 'record_storage.dart';
import 'requirements_store.dart';

/// Freezes selected input identity; the journal assigns the actual ordinal.
/// Neither capture nor preparation grants transport or execution authority.
final class SelectedRepairRequestCapture {
  SelectedRepairRequestCapture({
    required this.context,
    required Map<String, String> originals,
    required this.modelRequest,
  }) : sourceSha256 = Map.unmodifiable({
         for (final entry in originals.entries)
           entry.key: SelectedRepairRequest.fingerprint(entry.value),
       }) {
    if (context.selectedSessionBinding == null) {
      throw StateError('A selected repair session is required.');
    }
    context.requireCurrent();
  }

  final RepairRequestContext context;
  final ModelRequestProvenance modelRequest;
  final Map<String, String> sourceSha256;

  SelectedRepairRequest prepare(RepairAttempt reserved) {
    context.requireCurrent();
    final binding = context.selectedSessionBinding!;
    final board = RequirementsStore(context.records).load(context.projectId);
    final task = board.tasks.singleWhere((t) => t.id == binding.boardTaskId);
    final rawSession = context.selectedSessionRecord;
    if (rawSession == null || !context.matchesFailure(reserved.failure)) {
      throw StateError('Selected repair reservation context changed.');
    }
    final working = context.workingRecord;
    final origin = SelectedRepairRequest(
      projectId: context.projectId,
      attemptNumber: reserved.number,
      boardTaskId: task.id,
      requirementId: task.requirementId,
      requirementsRevision: board.revision,
      reservationSha256: SelectedRepairRequest.fingerprint(
        jsonEncode(reserved.toJson()),
      ),
      failedRunSha256: SelectedRepairRequest.fingerprint(
        jsonEncode(reserved.failure.toJson()),
      ),
      workingSha256: working == null
          ? null
          : SelectedRepairRequest.fingerprint(working),
      requestSessionRecord: rawSession,
      sourceSha256: sourceSha256,
      modelRequest: modelRequest,
    );
    origin.requireAttempt(reserved);
    return origin;
  }
}

/// Reads historical identities without checking current approval or working state.
/// Missing optional provenance never removes legacy journal/budget evidence.
final class SelectedRepairRequestStore {
  SelectedRepairRequestStore(this.records, this.projectId);
  final RecordStorage records;
  final String projectId;
  static const maxVisibleProjectAttempts = 32;

  SelectedRepairHistory load(String sessionId) {
    final reads = <String, String?>{};
    String? read(String key) {
      final value = records.getString(key);
      reads[key] = value;
      return value;
    }

    try {
      final raw = read('studio.repairAttempts.v1.$projectId');
      final journal = raw == null
          ? RepairAttemptJournal([])
          : RepairAttemptJournal.fromJson(
              jsonDecode(raw) as Map<String, dynamic>,
            );
      final omitted = journal.attempts.length > maxVisibleProjectAttempts
          ? journal.attempts.length - maxVisibleProjectAttempts
          : 0;
      final entries = <SelectedRepairHistoryEntry>[];
      for (final attempt in journal.attempts.skip(omitted).toList().reversed) {
        SelectedRepairRequest? origin;
        SelectedRepairRequestReference? reference;
        try {
          final key =
              '${SelectedRepairRequest.prefix}$projectId.${attempt.number}';
          final value = read(key);
          if (value != null) {
            final decoded = SelectedRepairRequest.decode(value);
            if (decoded.storageKey != key) {
              throw const FormatException('Repair origin identity changed.');
            }
            decoded.requireAttempt(attempt);
            if (decoded.requestSession.sessionId != sessionId) continue;
            origin = decoded;
            if (attempt.status == RepairAttemptStatus.proposed) {
              reference = SelectedRepairRequestReference.forProposed(
                decoded,
                attempt,
              );
            }
          }
        } catch (_) {
          origin = null;
          reference = null;
          // Optional unreadable records retain bare attempt facts only.
        }
        entries.add(
          SelectedRepairHistoryEntry(
            attempt: attempt,
            origin: origin,
            reference: reference,
          ),
        );
      }
      if (reads.entries.any((e) => records.getString(e.key) != e.value)) {
        throw StateError('Repair history changed while loading.');
      }
      return SelectedRepairHistory(entries, omittedProjectAttempts: omitted);
    } catch (_) {
      throw StateError(
        'Saved repair history is unavailable. Retry loading it.',
      );
    }
  }
}
