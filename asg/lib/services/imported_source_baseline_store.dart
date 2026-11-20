// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:path/path.dart' as path;

import '../models/imported_source_proposal_record.dart';
import '../models/project_source_observation.dart';
import 'record_storage.dart';
import 'inspected_folder_store.dart';
import 'requirements_store.dart';
import 'imported_plan_store.dart';
import 'imported_source_proposal_store.dart';
import 'runtime_setup_store.dart';

final class ImportedSourceBaselineSelection {
  ImportedSourceBaselineSelection._(
    this.saved,
    this.request,
    Map<String, String?> inputs,
  ) : inputs = Map.unmodifiable(inputs);
  final ImportedSourceProposalRecord saved;
  final ProjectSourceReadRequest request;
  final Map<String, String?> inputs;
}

/// Read-only app inputs and one in-process read lease per shared app store.
class ImportedSourceBaselineStore {
  ImportedSourceBaselineStore(this.records);
  final RecordStorage records;
  static final _readers = Expando<Object>();
  static const _changed =
      'Saved baseline inputs changed or could not be read. Reload history and check the folder and absolute Python configuration.';
  bool get readOwned => _readers[records] != null;
  Object acquireRead() {
    if (readOwned) {
      throw StateError(
        'An earlier source read still owns cleanup. Retry only after it finishes; uncertain cleanup requires reconciliation.',
      );
    }
    final token = Object();
    _readers[records] = token;
    return token;
  }

  void releaseRead(Object token) {
    if (identical(_readers[records], token)) _readers[records] = null;
  }

  bool _absolute(String value) =>
      value.length <= 4096 &&
      utf8.encode(value).length <= 4096 &&
      utf8.decode(utf8.encode(value)) == value &&
      path.isAbsolute(value) &&
      path.normalize(value) == value &&
      !value.contains(RegExp(r'[\x00-\x1f\x7f]'));

  ImportedSourceBaselineSelection prepare(
    ImportedSourceProposalRecord expected,
  ) {
    try {
      final root = expected.root,
          id = InspectedFolderStore.workspaceId(expected.root);
      final keys = [
        InspectedFolderStore.key,
        RequirementsStore.key(id),
        ImportedPlanStore.key(root),
        ImportedSourceProposalStore.key(root),
        'studio.runtimeSetup.v1',
      ];
      final inputs = {for (final key in keys) key: records.getString(key)};
      final saved = ImportedSourceProposalStore(records).history(root).record;
      if (saved == null ||
          saved.encode() != expected.encode() ||
          !InspectedFolderStore(records).load().contains(root)) {
        throw StateError(_changed);
      }
      RequirementsStore(records).load(id).validate();
      // Parse current app data without treating a historical review as approval.
      ImportedPlanStore(records).load(root);
      final python = RuntimeSetupStore(records).load().python;
      if (!_absolute(root) ||
          root == path.separator ||
          !_absolute(python) ||
          path.equals(root.toLowerCase(), python.toLowerCase()) ||
          path.isWithin(root.toLowerCase(), python.toLowerCase())) {
        throw StateError(_changed);
      }
      final selection = ImportedSourceBaselineSelection._(
        saved,
        ProjectSourceReadRequest(
          root: root,
          python: python,
          selectedPaths: saved.context.files.map((f) => f.path).toList(),
        ),
        inputs,
      );
      requireInputs(selection.inputs);
      return selection;
    } catch (_) {
      throw StateError(_changed);
    }
  }

  void requireInputs(Map<String, String?> inputs) {
    if (inputs.entries.any((e) => records.getString(e.key) != e.value)) {
      throw StateError(_changed);
    }
  }

  Future<void> verify(
    ImportedSourceBaselineSelection selection,
    void Function() alive,
  ) async {
    void check() {
      alive();
      requireInputs(selection.inputs);
    }

    try {
      check();
      final storage = records;
      if (storage is! ConditionalRecordStorage) throw StateError(_changed);
      await storage.commitRecords(
        expected: selection.inputs,
        updates: const {},
        authorize: check,
      );
      check();
    } catch (_) {
      throw StateError(_changed);
    }
  }
}
