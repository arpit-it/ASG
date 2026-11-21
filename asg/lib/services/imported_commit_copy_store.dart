// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import '../models/imported_commit_copy_record.dart';
import '../models/imported_commit_copy_request.dart';
import '../models/imported_commit_copy_observation.dart';
import '../models/imported_commit_proposal_record.dart';
import '../models/project_inspection.dart';
import 'imported_commit_proposal_store.dart';
import 'imported_source_baseline_store.dart';
import 'inspected_folder_store.dart';
import 'record_storage.dart';
import 'runtime_setup_store.dart';

final class ImportedCommitCopyHistory {
  ImportedCommitCopyHistory._(this.record, Map<String, String?> inputs)
    : inputs = Map.unmodifiable(inputs);
  final ImportedCommitCopyRecord record;
  final Map<String, String?> inputs;
}

final class ImportedCommitCopySelection {
  ImportedCommitCopySelection._(
    this.saved,
    this.python,
    this.history,
    Map<String, String?> inputs,
  ) : inputs = Map.unmodifiable(inputs);
  final ImportedCommitProposalRecord saved;
  final String python;
  final ImportedCommitCopyRecord history;
  final Map<String, String?> inputs;
}

/// Durable app admission/history only, never performs a native copy or reads disk.
class ImportedCommitCopyStore {
  ImportedCommitCopyStore(this.records);
  final RecordStorage records;
  static const prefix = 'studio.importedCommitCopy.v1.';
  static String key(String root) =>
      '$prefix${InspectedFolderStore.workspaceId(root)}';
  static const _runtime = 'studio.runtimeSetup.v1';
  static const _changed =
      'Saved immutable-copy inputs changed. Reload or reopen the app.';
  static final _owners = Expando<Object>();
  bool get readBusy => ImportedSourceBaselineStore(records).readOwned;
  Object acquire() {
    final token = ImportedSourceBaselineStore(records).acquireRead();
    _owners[records] = token;
    return token;
  }

  void release(Object token) {
    if (identical(_owners[records], token)) {
      ImportedSourceBaselineStore(records).releaseRead(token);
      _owners[records] = null;
    }
  }

  void requireLease(Object token) {
    if (!identical(_owners[records], token)) {
      throw StateError('Copy worker ownership changed.');
    }
  }

  ImportedCommitCopyHistory history(String root) {
    try {
      final target = key(root), raw = records.getString(key(root));
      final value = raw == null
          ? ImportedCommitCopyRecord.empty(root)
          : ImportedCommitCopyRecord.decode(raw);
      if (value.root != root) throw StateError(_changed);
      return ImportedCommitCopyHistory._(value, {target: raw});
    } catch (_) {
      throw StateError(
        'Immutable-copy history could not be reopened. Existing records are retained.',
      );
    }
  }

  ImportedCommitCopySelection read(ProjectInspection inspection) {
    try {
      final proposal = ImportedCommitProposalStore(records);
      final saved = proposal.history(inspection.root).record;
      if (saved == null) throw StateError(_changed);
      final selected = proposal.read(inspection, saved.context);
      final runtime = records.getString(_runtime);
      final python = RuntimeSetupStore(records).load().python;
      final savedHistory = history(inspection.root);
      if (jsonEncode(selected.plan.toJson()) !=
              jsonEncode(saved.plan.toJson()) ||
          python.isEmpty) {
        throw StateError(_changed);
      }
      final inputs = {
        ...selected.inputs,
        _runtime: runtime,
        ...savedHistory.inputs,
      };
      requireInputs(inputs);
      return ImportedCommitCopySelection._(
        saved,
        python,
        savedHistory.record,
        inputs,
      );
    } catch (_) {
      throw StateError(
        'A current approved committed proposal and trusted Python configuration are required. Reload after reviewing saved inputs.',
      );
    }
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
    ImportedCommitCopyRecord record,
    void Function() alive,
  ) async {
    final frozen = Map<String, String?>.unmodifiable(inputs),
        target = key(record.root);
    void check() {
      alive();
      requireInputs(frozen);
    }

    check();
    final checked = ImportedCommitCopyRecord.decode(record.recordJson),
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

  Future<ImportedCommitCopySelection> begin(
    ImportedCommitCopySelection selected,
    ImportedCommitCopyRequest request,
    DateTime at,
    void Function() alive,
  ) async {
    if (request.root != selected.saved.root ||
        request.python != selected.python ||
        request.historyDigest != selected.saved.digest ||
        request.contextDigest != selected.saved.context.digest ||
        request.planDigest != selected.saved.proposal.planDigest ||
        request.proposalDigest != selected.saved.proposal.digest) {
      throw StateError(_changed);
    }
    final rebuilt = ImportedCommitCopyRequest.create(
      saved: selected.saved,
      python: selected.python,
      destination: request.destination,
      attemptId: request.attemptId,
    );
    if (!rebuilt.matches(request)) throw StateError(_changed);
    final pending = selected.history.begin(request, at);
    await _write(selected.inputs, pending, alive);
    return ImportedCommitCopySelection._(
      selected.saved,
      selected.python,
      pending,
      {...selected.inputs, key(request.root): pending.recordJson},
    );
  }

  Future<ImportedCommitCopyRecord> complete(
    ImportedCommitCopySelection selected,
    ImportedCommitCopyRequest request,
    ImportedCommitCopyObservation result,
    DateTime at,
    void Function() alive,
  ) async {
    final value = selected.history.settle(request, result, at);
    await _write(selected.inputs, value, alive);
    return value;
  }

  /// Recovery can outlive plan changes; compare only the exact pending journal.
  /// It never promotes a prepared receipt or revives approval.
  Future<ImportedCommitCopyRecord> recover(
    ImportedCommitCopySelection pending,
    ImportedCommitCopyRequest request,
    ImportedCommitCopyObservation? result,
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

  Future<ImportedCommitCopyRecord> acknowledge(
    ImportedCommitCopyHistory selected,
    DateTime at,
    void Function() alive,
  ) async {
    final value = selected.record.acknowledge(at);
    await _write(selected.inputs, value, alive);
    return value;
  }
}
