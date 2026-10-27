// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/portable_project_archive.dart';
import '../models/portable_export_policy.dart';
import '../models/portable_export_redaction.dart';
import '../services/archive_file_service.dart';
import '../services/portable_prototype_store.dart';
import '../services/portable_export_records.dart';
import '../services/portable_conversation_store.dart';
import '../services/portable_archive_store.dart';
import '../services/portable_decision_store.dart';
import '../services/portable_revision_store.dart';
import '../services/portable_workspace_restore.dart';
import '../services/record_storage.dart';
import '../services/portable_project_store.dart';
import '../services/portable_requirements_store.dart';

class PortableArchiveController extends ChangeNotifier {
  PortableArchiveController(
    this.projectId,
    this.records, {
    ArchiveFileService? files,
  }) : files = files ?? ArchiveFileService();

  final String projectId;
  final ConditionalRecordStorage records;
  final ArchiveFileService files;
  PortableProjectArchive? _exportPreview;
  PortableProjectArchive? _exportDraft;

  /// Local review draft, including text that policy refuses to export.
  PortableProjectArchive? get exportReviewPreview => _exportDraft;
  String? get exportReviewContents => _exportDraft?.encode();
  PortableProjectArchive? _importPreview;
  PortableProjectArchive? get exportPreview => _exportPreview;
  PortableProjectArchive? get importPreview => _importPreview;

  /// The complete validated snapshot used by export and restore, for plain-text
  /// review of fields that the readable summary does not display.
  String? get exportContents => _exportPreview?.encode();
  String? get importContents => _importPreview?.encode();
  bool _disposed = false;
  bool _busy = false;
  bool get busy => _busy;
  String? _error;
  String? get error => _error;
  String? _status;
  String? get status => _status;

  Future<void> _run(Future<void> Function() action) async {
    if (_disposed || _busy) return;
    _busy = true;
    _error = null;
    _status = null;
    notifyListeners();
    try {
      await action();
    } on PortableExportRefused {
      if (!_disposed) {
        _exportPreview = null;
        _error = PortableExportRefused.message;
      }
    } on TimeoutException {
      if (!_disposed) {
        _error =
            'Reading the archive timed out. Select the file again to retry. '
            'Existing records have not been replaced.';
      }
    } catch (_) {
      if (!_disposed) {
        _error = 'Operation failed. Check the file, supported format and backup ID, then retry. Existing records have not been replaced.';
      }
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> prepareExport() => _run(() async {
    _exportPreview = null;
    _exportDraft = null;
    final source = PortableExportRecords(records);
    final archive = PortableProjectArchive(
      project: PortableProjectStore(source).load(projectId),
      requirements: PortableRequirementsStore(source).load(projectId),
      prototype: PortablePrototypeStore(source).load(projectId),
      decision: PortableDecisionStore(source).load(projectId),
      revisions: PortableRevisionStore(source).load(projectId),
      messages: PortableConversationStore(source).load(projectId),
    );
    final draft = PortableProjectArchive.decode(archive.encode());
    _exportDraft = draft;
    PortableExportPolicy.requireExportable(draft);
    _exportPreview = draft;
    _status = 'Saved records loaded for export. Review before sharing.';
  });

  Future<void> redactExport(String literal) => _run(() async {
    final draft = _exportDraft;
    if (draft == null) throw StateError('Load saved records first.');
    final PortableExportRedaction result;
    try {
      result = PortableExportRedaction.apply(draft, literal);
    } on FormatException {
      _error =
          'Redaction failed. Enter nonempty matching authored text. '
          'The result must fit archive field limits. The review copy and saved records are unchanged.';
      return;
    }
    _exportDraft = result.archive;
    _exportPreview = null;
    PortableExportPolicy.requireExportable(result.archive);
    _exportPreview = result.archive;
    _status =
        '${result.matches} literal matches redacted in the export copy. '
        'Review the updated archive before sharing. Saved records are unchanged.';
  });

  Future<void> exportFile() => _run(() async {
    final preview = _exportPreview;
    if (preview == null) throw StateError('Load saved records first.');
    final validated = PortableProjectArchive.decode(preview.encode());
    PortableExportPolicy.requireExportable(validated);
    final saved = await files.export(validated.encode());
    if (!_disposed) {
      _status = saved ? files.exportSuccessMessage : 'Export cancelled.';
    }
  });

  Future<void> prepareCopyExport(String id) => _run(() async {
    _exportPreview = null;
    _exportDraft = null;
    final archive = PortableArchiveStore(records).load(id);
    if (archive == null) throw StateError('Saved copy not found.');
    final draft = PortableProjectArchive.decode(archive.encode());
    _exportDraft = draft;
    PortableExportPolicy.requireExportable(draft);
    _exportPreview = draft;
    _status = 'Saved copy loaded for export. Review before sharing.';
  });

  Future<void> pickImport() => _run(() async {
    _importPreview = null;
    final encoded = await files.pickImport();
    if (_disposed) return;
    if (encoded == null) {
      _status = 'File selection cancelled.';
      return;
    }
    _importPreview = null;
    _importPreview = PortableProjectArchive.decode(encoded);
    _status = 'File validated. Nothing imported yet.';
  });

  Future<void> loadCopy(String id) => _run(() async {
    _importPreview = null;
    final archive = PortableArchiveStore(records).load(id);
    if (archive == null) throw StateError('Saved copy not found.');
    _importPreview = archive;
    _status = 'Saved copy loaded. Review before restoring; nothing changed.';
  });

  Future<void> saveCopy(String id) => _run(() async {
    final preview = _importPreview;
    if (preview == null) throw StateError('Select a valid archive first.');
    await PortableArchiveStore(records).restoreCopy(id, preview.encode());
    if (!_disposed) {
      _importPreview = null;
      _status =
          'Data copy saved as $id. No executable project or approval was created.';
    }
  });

  Future<void> restoreWorkspace(String id, String name) => _run(() async {
    final preview = _importPreview;
    if (preview == null) throw StateError('Select a valid archive first.');
    final project = await PortableWorkspaceRestore(records)
        .restore(id: id, name: name, encoded: preview.encode());
    if (!_disposed) {
      _importPreview = null;
      _status =
          'Project "${project.name}" saved. Open it from Projects. '
          '${preview.prototype == null ? 'Its prototype starts fresh' : 'Its saved prototype is restored'}; create and approve a new Plan before building.';
    }
  });

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
