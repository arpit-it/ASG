// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/imported_commit_edit_record.dart';
import '../models/imported_commit_edit_request.dart';
import '../models/imported_commit_edit_observation.dart';
import '../models/imported_commit_proposal_record.dart';
import '../models/project_inspection.dart';
import 'imported_commit_copy_store.dart';
import '../models/imported_commit_copy_record.dart';
import '../models/imported_commit_copy_recheck.dart';
import 'inspected_folder_store.dart';
import 'record_storage.dart';

final class ImportedCommitEditHistory {
  ImportedCommitEditHistory._(this.record, Map<String, String?> inputs)
    : inputs = Map.unmodifiable(inputs);
  final ImportedCommitEditRecord record;
  final Map<String, String?> inputs;
}

final class ImportedCommitEditSelection {
  ImportedCommitEditSelection._(
    this.saved,
    this.python,
    this.history,
    this.copyHistory,
    Map<String, String?> inputs,
  ) : inputs = Map.unmodifiable(inputs);
  final ImportedCommitProposalRecord saved;
  final String python;
  final ImportedCommitEditRecord history;
  final ImportedCommitCopyRecord copyHistory;
  final Map<String, String?> inputs;
}

/// Durable app admission/history only, never performs a native copy or reads disk.
class ImportedCommitEditStore {
  ImportedCommitEditStore(this.records);
  final RecordStorage records;
  static const prefix = 'studio.importedCommitEdit.v1.';
  static String key(String root) =>
      '$prefix${InspectedFolderStore.workspaceId(root)}';
  static const _changed =
      'Saved proposed-copy inputs changed. Reload or reopen the app.';
  ImportedCommitCopyStore get _copies => ImportedCommitCopyStore(records);
  bool get readBusy => _copies.readBusy;
  Object acquire() => _copies.acquire();
  void release(Object token) => _copies.release(token);
  void requireLease(Object token) => _copies.requireLease(token);

  ImportedCommitEditHistory history(String root) {
    try {
      final target = key(root), raw = records.getString(key(root));
      final value = raw == null
          ? ImportedCommitEditRecord.empty(root)
          : ImportedCommitEditRecord.decode(raw);
      if (value.root != root) throw StateError(_changed);
      return ImportedCommitEditHistory._(value, {target: raw});
    } catch (_) {
      throw StateError(
        'Proposed-copy history could not be reopened. Existing records are retained.',
      );
    }
  }

  ImportedCommitEditSelection read(ProjectInspection inspection) {
    final current = ImportedCommitCopyStore(records).read(inspection);
    final journal = history(inspection.root);
    final inputs = {...current.inputs, ...journal.inputs};
    requireInputs(inputs);
    return ImportedCommitEditSelection._(
      current.saved,
      current.python,
      journal.record,
      current.history,
      inputs,
    );
  }

  void requireInputs(Map<String, String?> inputs) {
    if (inputs.entries.any((e) => records.getString(e.key) != e.value)) {
      throw StateError(_changed);
    }
  }

  Future<void> verify(
    Map<String, String?> inputs,
    void Function() alive,
  ) async {
    final frozen = Map<String, String?>.unmodifiable(inputs);
    void check() {
      alive();
      requireInputs(frozen);
    }

    check();
    final storage = records;
    if (storage is! ConditionalRecordStorage) {
      throw StateError('Transactional app storage is required.');
    }
    await storage.commitRecords(
      expected: frozen,
      updates: const {},
      authorize: check,
    );
    check();
  }

  Future<void> _write(
    Map<String, String?> inputs,
    ImportedCommitEditRecord record,
    void Function() alive,
  ) async {
    final frozen = Map<String, String?>.unmodifiable(inputs),
        target = key(record.root);
    void check() {
      alive();
      requireInputs(frozen);
    }

    check();
    final checked = ImportedCommitEditRecord.decode(record.recordJson),
        storage = records;
    if (storage is! ConditionalRecordStorage || !frozen.containsKey(target)) {
      throw StateError(_changed);
    }
    await storage.commitRecords(
      expected: frozen,
      updates: {target: checked.recordJson},
      authorize: check,
    );
    alive();
    requireInputs({...frozen, target: checked.recordJson});
  }

  Future<ImportedCommitEditSelection> begin(
    ImportedCommitEditSelection selected,
    ImportedCommitEditRequest request,
    ImportedCommitCopyRecheckRequest reviewed,
    ImportedCommitCopyRecheckObservation observed,
    DateTime at,
    void Function() alive,
  ) async {
    final rebuilt = ImportedCommitEditRequest.create(
      copyHistory: selected.copyHistory,
      proposal: selected.saved,
      reviewed: reviewed,
      observation: observed,
      python: selected.python,
      destination: request.destination,
      attemptId: request.attemptId,
    );
    if (!rebuilt.matches(request)) throw StateError(_changed);
    final pending = selected.history.begin(request, at);
    await _write(selected.inputs, pending, alive);
    return ImportedCommitEditSelection._(
      selected.saved,
      selected.python,
      pending,
      selected.copyHistory,
      {...selected.inputs, key(request.root): pending.recordJson},
    );
  }

  Future<ImportedCommitEditRecord> complete(
    ImportedCommitEditSelection selected,
    ImportedCommitEditRequest request,
    ImportedCommitEditObservation result,
    DateTime at,
    void Function() alive,
  ) async {
    final value = selected.history.settle(request, result, at);
    await _write(selected.inputs, value, alive);
    return value;
  }

  /// Recovery can outlive plan changes; compare only the exact pending journal.
  /// It never promotes a prepared receipt or revives approval.
  Future<ImportedCommitEditRecord> recover(
    ImportedCommitEditSelection pending,
    ImportedCommitEditRequest request,
    ImportedCommitEditObservation? result,
    DateTime at,
    void Function() alive,
  ) async {
    final value = pending.history.settle(
      request,
      result,
      at,
      unconfirmed: true,
    );
    await _write(
      {key(request.root): pending.inputs[key(request.root)]},
      value,
      alive,
    );
    return value;
  }

  Future<ImportedCommitEditRecord> acknowledge(
    ImportedCommitEditHistory selected,
    DateTime at,
    void Function() alive,
  ) async {
    final value = selected.record.acknowledge(at);
    await _write(selected.inputs, value, alive);
    return value;
  }
}
