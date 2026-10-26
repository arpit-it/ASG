import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/portable_project_archive.dart';
import '../services/archive_file_service.dart';
import '../services/portable_prototype_store.dart';
import '../services/portable_export_records.dart';
import '../services/conversation_store.dart';
import '../services/portable_archive_store.dart';
import '../services/portable_decision_store.dart';
import '../services/portable_revision_store.dart';
import '../services/portable_workspace_restore.dart';
import '../services/record_storage.dart';
import '../services/requirements_store.dart';

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
  PortableProjectArchive? _importPreview;
  PortableProjectArchive? get exportPreview => _exportPreview;
  PortableProjectArchive? get importPreview => _importPreview;
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
    final source = PortableExportRecords(records);
    final archive = PortableProjectArchive(
      requirements: RequirementsStore(source).load(projectId),
      prototype: PortablePrototypeStore(source).load(projectId),
      decision: PortableDecisionStore(source).load(projectId),
      revisions: PortableRevisionStore(source).load(projectId),
      messages: ConversationStore(source).load(projectId),
    );
    archive.encode();
    _exportPreview = archive;
    _status = 'Saved records loaded for export. Review before sharing.';
  });

  Future<void> exportFile() => _run(() async {
    final preview = _exportPreview;
    if (preview == null) throw StateError('Load saved records first.');
    final saved = await files.export(preview.encode());
    if (!_disposed) {
      _status = saved ? 'Archive file saved.' : 'Export cancelled.';
    }
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
