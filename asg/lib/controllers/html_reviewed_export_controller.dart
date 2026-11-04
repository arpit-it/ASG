// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';

import '../models/html/html_export_request.dart';
import '../models/html/html_source_proposal.dart';
import '../services/folder_picker.dart';
import '../services/html/html_source_export.dart';
import 'base_controller.dart';

/// Session-only confirmation of untrusted source export. No execution authority.
class HtmlReviewedExportController extends BaseController {
  HtmlReviewedExportController({
    required this.proposal,
    required this.authorizeSource,
    required this.exporter,
    FolderPicker? picker,
    this.deadline = const Duration(seconds: 10),
  }) : assert(deadline > Duration.zero),
       _picker = picker ?? FolderPicker();

  final HtmlSourceProposal proposal;
  final void Function() authorizeSource;
  final HtmlReviewedSourceExport exporter;
  final FolderPicker _picker;
  final Duration deadline;
  bool _busy = false, _picking = false, _stopped = false;
  int _generation = 0;
  String _parent = '', _folder = '';
  String? _error, _destination;
  HtmlReviewedExportRequest? _review;
  bool get busy => _busy;
  bool get picking => _picking;
  bool get supported => exporter.supported;
  String get parent => _parent;
  String get folder => _folder;
  String? get error => _error;
  String? get destination => _destination;
  HtmlReviewedExportRequest? get review => _review;

  void _invalidate() {
    _generation++;
    _review = null;
    _destination = null;
    _error = null;
    _stopped = false;
  }

  void editFolder(String value) {
    if (isDisposed || _busy || _picking) return;
    _invalidate();
    _folder = value;
    update();
  }

  Future<void> pickParent() async {
    if (isDisposed || _busy || _picking || !supported) return;
    _invalidate();
    _picking = true;
    update();
    try {
      if (isDisposed) throw StateError('Export closed.');
      authorizeSource();
      final selected = await _picker.pick();
      if (isDisposed) return;
      authorizeSource();
      if (selected != null) _parent = selected;
    } catch (_) {
      if (!isDisposed) _error = 'Folder selection failed or source review changed. Return to source review and retry.';
    } finally {
      _picking = false;
      update();
    }
  }

  void prepareReview() {
    if (isDisposed || _busy || _picking) return;
    _invalidate();
    try {
      authorizeSource();
      if (!supported) throw StateError('Unsupported host.');
      if (_parent.isEmpty ||
          !RegExp(r'^[a-z][a-z0-9_]{2,50}$').hasMatch(_folder)) {
        _error = 'Choose a parent folder and a new 3–51 character lowercase folder name (letters, digits, underscore; start with a letter).';
      } else {
        _review = HtmlReviewedExportRequest(
          proposal: proposal,
          parent: _parent,
          folderName: _folder,
        );
      }
    } catch (_) {
      _error = 'Export unavailable or source review changed. Return to source review and request fresh source.';
    }
    update();
  }

  Future<void> confirm(HtmlReviewedExportRequest displayed) async {
    if (isDisposed ||
        _busy ||
        _picking ||
        !supported ||
        !identical(displayed, _review)) {
      return;
    }
    final generation = _generation;
    _busy = true;
    _error = null;
    update();
    void authorize() {
      if (isDisposed ||
          _stopped ||
          generation != _generation ||
          !identical(displayed, _review)) {
        throw StateError('Export revoked.');
      }
      authorizeSource();
    }

    final timer = Timer(deadline, () {
      if (isDisposed || !_busy || generation != _generation) return;
      stop();
      _error = 'Export deadline reached. Already-dispatched writes may finish; inspect the confirmed destination. Nothing was removed.';
      update();
    });
    try {
      authorize();
      final result = await exporter.exportReviewed(
        request: displayed,
        confirmedRequest: displayed,
        authorizeWrite: authorize,
      );
      authorize();
      _destination = result;
    } on HtmlExportFailure catch (failure) {
      if (!isDisposed) _error = [?_error, failure.toString()].join('\n');
    } catch (_) {
      if (!isDisposed) _error ??= 'Export failed, stopped or source review changed. Inspect the confirmed destination before a fresh review; already-dispatched writes may finish. Nothing was removed.';
    } finally {
      timer.cancel();
      _error = _error?.replaceFirst(
        'Waiting for dispatched IO to settle;',
        'The export request has returned;',
      );
      _review = null;
      _generation++;
      _busy = false;
      update();
    }
  }

  void stop() {
    if (isDisposed || !_busy || _stopped) return;
    _stopped = true;
    _generation++;
    _error = 'Export stopped. Waiting for dispatched IO to settle; already-dispatched writes may finish. Inspect the confirmed destination. Nothing was removed.';
    update();
  }

  @override
  void dispose() {
    _generation++;
    _review = null;
    super.dispose();
  }
}
