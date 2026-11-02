// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';

import '../models/project.dart';
import '../services/html/html_project_store.dart';

import '../models/html/saved_html_starter.dart';
import '../services/html/html_starter_store.dart';

import '../models/html/html_source_check.dart';
import '../services/html/html_source_check.dart';

import '../services/html/html_preview.dart';
import '../services/html/html_starter_runner.dart';
import '../services/project_runner_registry.dart';
import '../models/project_runner.dart';
import 'html_preview_controller.dart';
import '../models/html/html_export_request.dart';
import '../models/html/html_site_input.dart';
import '../services/folder_picker.dart';
import '../services/html/html_source_export.dart';
import 'base_controller.dart';

/// Explicit export and metadata registration; neither grants Build authority.
class HtmlExportController extends BaseController {
  HtmlExportController({
    required HtmlSourceExport exporter,
    HtmlStarterStore? starterStore,
    SavedHtmlStarter? savedStarter,
    HtmlSiteInput? initialInput,
    FolderPicker? folderPicker,
    HtmlPreview? previewService,
    HtmlSourceChecker? sourceChecker,
  }) : this._(
         exporter: exporter,
         starterStore: starterStore,
         savedStarter: savedStarter,
         initialInput: initialInput,
         folderPicker: folderPicker,
         registry: ProjectRunnerRegistry(
           html: HtmlStarterRunner(
             checker: sourceChecker,
             preview: previewService,
           ),
         ),
       );

  HtmlExportController._({
    required this.exporter,
    required this.starterStore,
    required SavedHtmlStarter? savedStarter,
    required HtmlSiteInput? initialInput,
    FolderPicker? folderPicker,
    required ProjectRunnerRegistry registry,
  }) : runner = registry.htmlRunner('HTML')!,
       _picker = folderPicker ?? FolderPicker(),
       preview = HtmlPreviewController(registry.htmlRunner('HTML')!) {
    if (initialInput != null && savedStarter != null) {
      throw ArgumentError('Choose a new draft or a saved starter.');
    }
    if (initialInput != null) {
      _title = initialInput.title;
      _description = initialInput.description;
    }
    if (savedStarter != null) {
      _title = savedStarter.input.title;
      _description = savedStarter.input.description;
      _exportedDirectory = savedStarter.directory;
      // Reopen grants no checks, preview or write authority.
      final slash = savedStarter.directory.lastIndexOf('/');
      _parent = slash == 0 ? '/' : savedStarter.directory.substring(0, slash);
      _folder = savedStarter.directory.substring(slash + 1);
      _exportedRequest = HtmlExportRequest(
        input: savedStarter.input,
        parent: _parent,
        folderName: _folder,
      );
      _saved = true;
    }
  }

  final HtmlStarterStore? starterStore;
  bool _registering = false;
  StudioProject? _registeredProject;
  String? _registrationError;
  bool get registering => _registering;
  StudioProject? get registeredProject => _registeredProject;
  String? get registrationError => _registrationError;

  Future<void> registerProject() async {
    final store = starterStore;
    final request = _exportedRequest;
    final directory = _exportedDirectory;
    if (isDisposed ||
        _registering ||
        _saving ||
        _busy ||
        _picking ||
        _registeredProject != null ||
        store == null ||
        request == null ||
        directory == null) {
      return;
    }
    _registering = true;
    _registrationError = null;
    update();
    try {
      final project = await HtmlProjectStore(store.records).register(
        SavedHtmlStarter(directory: directory, input: request.input),
        authorize: () {
          if (isDisposed) throw StateError('Registration revoked.');
        },
      );
      if (!isDisposed) {
        _registeredProject = project;
        _saved = true;
      }
    } catch (_) {
      if (!isDisposed) _registrationError = 'HTML project could not be registered. Exported files are retained. Check local storage and retry registration; do not export again.';
    } finally {
      _registering = false;
      update();
    }
  }

  bool _saving = false, _saved = false;
  String? _saveError;
  bool get saving => _saving;
  bool get saved => _saved;
  String? get saveError => _saveError;
  String get title => _title;
  String get description => _description;
  String get folder => _folder;

  Future<void> saveStarter() async {
    final store = starterStore;
    final request = _exportedRequest;
    final directory = _exportedDirectory;
    if (isDisposed ||
        _saving ||
        _registering ||
        _saved ||
        _busy ||
        store == null ||
        request == null ||
        directory == null) {
      return;
    }
    _saving = true;
    _saveError = null;
    update();
    try {
      await store.save(
        SavedHtmlStarter(directory: directory, input: request.input),
      );
      if (!isDisposed) _saved = true;
    } catch (_) {
      if (!isDisposed) _saveError = 'Starter could not be saved. Exported files are retained. Check local storage and retry saving; do not export again.';
    } finally {
      _saving = false;
      update();
    }
  }

  final HtmlSourceExport exporter;
  final HtmlStarterRunner runner;
  HtmlSourceChecker get checker => runner.sourceChecker;
  ProjectRunnerDescriptor get runnerDescriptor => runner.descriptor;
  HtmlSourceCheck? _sourceCheck;
  String? _checkError;
  bool _checking = false, _checkStopped = false;
  int _checkGeneration = 0;
  HtmlSourceCheck? get sourceCheck => _sourceCheck;
  String? get checkError => _checkError;
  bool get checking => _checking;
  bool get checkStopped => _checkStopped;

  Future<void> checkExport() async {
    final request = _exportedRequest;
    final directory = _exportedDirectory;
    if (isDisposed ||
        _checking ||
        _busy ||
        !checker.supported ||
        request == null ||
        directory == null) {
      return;
    }
    final generation = ++_checkGeneration;
    _checking = true;
    _checkStopped = false;
    _sourceCheck = null;
    _checkError = null;
    update();
    void authorize() {
      if (isDisposed || generation != _checkGeneration) {
        throw StateError('Source check revoked.');
      }
    }

    final deadline = Timer(const Duration(seconds: 10), () {
      if (!isDisposed && _checking && generation == _checkGeneration) {
        stopCheck();
        _checkError = 'Source check reached its 10-second deadline. Waiting for pending file IO to settle before retry.';
        update();
      }
    });
    try {
      final result = await runner.checkSources(
        directory: directory,
        input: request.input,
        authorizeRead: authorize,
      );
      authorize();
      _sourceCheck = result;
    } catch (_) {
      if (!isDisposed && generation == _checkGeneration) {
        _checkError = 'Source verification failed. Files may be missing, changed, symbolic or unreadable. Nothing was changed; restore the exact starter before retry.';
      }
    } finally {
      deadline.cancel();
      _checking = false;
      update();
    }
  }

  void stopCheck() {
    if (isDisposed || !_checking || _checkStopped) return;
    _checkGeneration++;
    _checkStopped = true;
    _sourceCheck = null;
    _checkError = 'Source check stopped. Pending file IO may still settle; no files were changed.';
    update();
  }

  final FolderPicker _picker;
  final HtmlPreviewController preview;
  HtmlExportRequest? _exportedRequest;
  String _title = '', _description = '', _parent = '', _folder = '';
  HtmlExportRequest? _review;
  bool _busy = false, _picking = false, _stopped = false;
  int _authority = 0;
  Timer? _exportDeadline;
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
    if (isDisposed || _busy || _picking || _saving || _registering) return;
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
    _checkGeneration++;
    _sourceCheck = null;
    if (_checking) _checkStopped = true;
    _checkError = _checking
        ? 'Source check invalidated by changed inputs. Its late result will be ignored; no files were changed.'
        : null;
    _exportedRequest = null;
    _saved = false;
    _registeredProject = null;
    _registrationError = null;
    _saveError = null;
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
    if (isDisposed ||
        _busy ||
        _picking ||
        _saving ||
        _registering ||
        !supported) {
      return;
    }
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
    if (isDisposed || _busy || _picking || _saving || _registering) return;
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
        _saving ||
        _registering ||
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

    _exportDeadline = Timer(const Duration(seconds: 10), () {
      if (!isDisposed && _busy && authority == _authority) {
        stop();
        _error = 'Export reached its 10-second deadline. Waiting for dispatched IO to settle before retry. Already-dispatched writes may finish; inspect the confirmed destination. Nothing was removed.';
        update();
      }
    });
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
      if (!isDisposed) {
        // Keep any deadline explanation alongside partial-path/process evidence.
        _error = [?_error, failure.toString()].join('\n');
      }
    } catch (_) {
      if (!isDisposed && _error == null) {
        _error = _stopped
            ? 'Export stopped. An already-dispatched write may have completed. Inspect the selected destination before a fresh review; nothing was removed.'
            : 'Export failed. Inspect the selected destination and choose a new folder before a fresh review. Nothing was removed.';
      }
    } finally {
      _exportDeadline?.cancel();
      _exportDeadline = null;
      _error = _error?.replaceFirst(
        'Waiting for dispatched IO to settle before retry.',
        'The pending export request has returned. Inspect the destination and choose a new folder before a fresh review.',
      );
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
    _exportDeadline?.cancel();
    _exportDeadline = null;
    _checkGeneration++;
    preview.dispose();
    _exportedRequest = null;
    _authority++;
    _review = null;
    super.dispose();
  }
}
