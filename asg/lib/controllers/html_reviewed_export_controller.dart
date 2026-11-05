// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';

import '../models/html/html_export_request.dart';
import '../models/html/html_source_proposal.dart';
import '../services/folder_picker.dart';
import '../services/html/html_source_export.dart';
import '../services/html/html_reviewed_source_check.dart';
import 'base_controller.dart';

/// Session-only confirmation of untrusted source export. No execution authority.
class HtmlReviewedExportController extends BaseController {
  HtmlReviewedExportController({
    required this.proposal,
    required this.authorizeSource,
    required this.exporter,
    FolderPicker? picker,
    HtmlReviewedSourceChecker? sourceChecker,
    this.deadline = const Duration(seconds: 10),
  }) : assert(deadline > Duration.zero),
       _picker = picker ?? FolderPicker(),
       sourceChecker = sourceChecker ?? createHtmlReviewedSourceChecker();

  final HtmlSourceProposal proposal;
  final void Function() authorizeSource;
  final HtmlReviewedSourceExport exporter;
  final FolderPicker _picker;
  final Duration deadline;
  final HtmlReviewedSourceChecker sourceChecker;
  bool _checking = false, _checkStopped = false;
  HtmlReviewedSourceCheck? _sourceCheck;
  String? _checkError;
  bool get checking => _checking;
  bool get checkStopped => _checkStopped;
  bool get checkSupported => sourceChecker.supported;

  /// Completed identity evidence is meaningful only for the current review.
  /// Keep the destination separately so revoked reviews retain recovery paths.
  HtmlReviewedSourceCheck? get sourceCheck =>
      sourceCurrent ? _sourceCheck : null;

  bool get sourceCurrent {
    if (isDisposed) return false;
    try {
      authorizeSource();
      return true;
    } catch (_) {
      return false;
    }
  }

  String? get checkError => _checkError;

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
    _sourceCheck = null;
    _checkError = null;
    _review = null;
    _destination = null;
    _error = null;
    _stopped = false;
  }

  void editFolder(String value) {
    if (isDisposed || _busy || _picking || _checking) return;
    _invalidate();
    _folder = value;
    update();
  }

  Future<void> pickParent() async {
    if (isDisposed || _busy || _picking || _checking || !supported) return;
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
    if (isDisposed || _busy || _picking || _checking) return;
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
        _checking ||
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

  Future<void> checkExport() async {
    final directory = _destination;
    if (isDisposed ||
        _busy ||
        _picking ||
        _checking ||
        directory == null ||
        !checkSupported) {
      return;
    }
    final generation = _generation;
    _checking = true;
    _checkStopped = false;
    _sourceCheck = null;
    _checkError = null;
    update();
    void authorize() {
      if (isDisposed ||
          _checkStopped ||
          generation != _generation ||
          directory != _destination) {
        throw StateError('Read revoked.');
      }
      authorizeSource();
    }

    final timer = Timer(deadline, () {
      if (isDisposed || !_checking || generation != _generation) return;
      stopCheck();
      _checkError = 'Source identity deadline reached. Waiting for dispatched reads to settle. Nothing was changed.';
      update();
    });
    try {
      authorize();
      final result = await sourceChecker.check(
        directory: directory,
        proposal: proposal,
        authorizeRead: authorize,
      );
      authorize();
      _sourceCheck = result;
    } catch (_) {
      if (!isDisposed) _checkError ??= 'Source identity check failed, stopped or review changed. Source remains untrusted. Nothing was changed.';
    } finally {
      timer.cancel();
      _checkError = _checkError?.replaceFirst(
        'Waiting for dispatched reads to settle.',
        'The source identity request has returned.',
      );
      _checking = false;
      update();
    }
  }

  void stopCheck() {
    if (isDisposed || !_checking || _checkStopped) return;
    _checkStopped = true;
    _sourceCheck = null;
    _checkError = 'Source identity check stopped. Waiting for dispatched reads to settle. Nothing was changed.';
    update();
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
    _sourceCheck = null;
    _checkError = null;
    _review = null;
    super.dispose();
  }
}
