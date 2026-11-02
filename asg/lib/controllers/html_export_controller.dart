// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';

import '../services/html/html_preview.dart';
import '../services/html/html_preview_factory.dart';
import 'html_preview_controller.dart';
import '../models/html/html_export_request.dart';
import '../models/html/html_site_input.dart';
import '../services/folder_picker.dart';
import '../services/html/html_source_export.dart';
import 'base_controller.dart';

/// Session confirmation only. Nothing here registers a runnable ASG project.
class HtmlExportController extends BaseController {
  HtmlExportController({
    required this.exporter,
    FolderPicker? folderPicker,
    HtmlPreview? previewService,
  }) : _picker = folderPicker ?? FolderPicker(),
       preview = HtmlPreviewController(previewService ?? createHtmlPreview());

  final HtmlSourceExport exporter;
  final FolderPicker _picker;
  final HtmlPreviewController preview;
  HtmlExportRequest? _exportedRequest;
  String _title = '', _description = '', _parent = '', _folder = '';
  HtmlExportRequest? _review;
  bool _busy = false, _picking = false, _stopped = false;
  int _authority = 0;
  String? _error, _exportedDirectory;

  bool get supported => exporter.supported;
  bool get busy => _busy;
  bool get picking => _picking;
  bool get stopped => _stopped;
  String get parent => _parent;
  String? get error => _error;
  String? get exportedDirectory => _exportedDirectory;
  HtmlExportRequest? get review => _review;

  void edit({String? title, String? description, String? folder}) {
    if (isDisposed || _busy || _picking) return;
    _title = title ?? _title;
    _description = description ?? _description;
    _folder = folder ?? _folder;
    _invalidate();
    update();
  }

  Future<void> startPreview() async {
    final request = _exportedRequest;
    final directory = _exportedDirectory;
    if (isDisposed || _busy || request == null || directory == null) return;
    await preview.start(directory, request);
  }

  void _invalidate() {
    _exportedRequest = null;
    if (preview.url != null || preview.busy || preview.cleanupFailed) {
      unawaited(preview.stop());
    }
    _authority++;
    _review = null;
    _error = null;
    _exportedDirectory = null;
    _stopped = false;
  }

  Future<void> pickParent() async {
    if (isDisposed || _busy || _picking || !supported) return;
    _invalidate();
    _picking = true;
    update();
    try {
      final selected = await _picker.pick();
      if (!isDisposed && selected != null) _parent = selected;
    } catch (_) {
      if (!isDisposed) {
        _error = 'Unable to choose a parent folder. Retry selection.';
      }
    } finally {
      _picking = false;
      update();
    }
  }

  void prepareReview() {
    if (isDisposed || _busy || _picking) return;
    _invalidate();
    try {
      if (!supported) {
        throw UnsupportedError('HTML source export requires macOS.');
      }
      if (_parent.isEmpty ||
          !RegExp(r'^[a-z][a-z0-9_]{2,50}$').hasMatch(_folder)) {
        throw const FormatException(
          'Choose a parent and a new 3–51 character lowercase folder name (letters, digits, underscore; start with a letter).',
        );
      }
      _review = HtmlExportRequest(
        input: HtmlSiteInput(title: _title, description: _description),
        parent: _parent,
        folderName: _folder,
      );
    } on FormatException catch (failure) {
      _error = failure.message;
    } on UnsupportedError catch (failure) {
      _error = failure.message;
    }
    update();
  }

  Future<void> confirm(HtmlExportRequest displayedReview) async {
    if (isDisposed ||
        _busy ||
        _picking ||
        !supported ||
        !identical(displayedReview, _review)) {
      return;
    }
    final authority = _authority;
    _busy = true;
    _error = null;
    update();
    void authorize() {
      if (isDisposed ||
          _stopped ||
          authority != _authority ||
          !identical(displayedReview, _review)) {
        throw StateError('HTML export authority was revoked.');
      }
    }

    try {
      final destination = await exporter.export(
        request: displayedReview,
        confirmedRequest: displayedReview,
        authorizeWrite: authorize,
      );
      // Completion after Stop/disposal cannot publish success.
      authorize();
      _exportedDirectory = destination;
      _exportedRequest = displayedReview;
    } on HtmlExportFailure catch (failure) {
      if (!isDisposed) _error = failure.toString();
    } catch (_) {
      if (!isDisposed) {
        _error = _stopped
            ? 'Export stopped. An already-dispatched write may have completed. Inspect the selected destination before a fresh review; nothing was removed.'
            : 'Export failed. Inspect the selected destination and choose a new folder before a fresh review. Nothing was removed.';
      }
    } finally {
      _review = null;
      _authority++;
      _busy = false;
      update();
    }
  }

  void stop() {
    if (isDisposed || !_busy || _stopped) return;
    _authority++;
    _stopped = true;
    update();
  }

  @override
  void dispose() {
    preview.dispose();
    _exportedRequest = null;
    _authority++;
    _review = null;
    super.dispose();
  }
}
