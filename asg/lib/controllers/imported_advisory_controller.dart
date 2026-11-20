// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';

import '../models/imported_advisory_request.dart';
import '../models/imported_advisory_record.dart';
import '../models/imported_repository_context.dart';
import '../models/project_inspection.dart';
import '../services/imported_advisory_store.dart';
import '../services/local_model.dart';
import '../services/model_provider.dart';
import 'base_controller.dart';

class ImportedAdvisoryController extends BaseController {
  ImportedAdvisoryController({
    required this.inspection,
    required this.context,
    required this.store,
    ProviderFactory? createProvider,
    this.requestLimit = const Duration(minutes: 3),
    this.cleanupLimit = const Duration(seconds: 2),
  }) : _createProvider =
           createProvider ??
           ((config) => LocalModelProvider(
             config,
             maxTokens: config.chatOutputTokens,
             totalTimeout: requestLimit,
           ));
  final ProjectInspection inspection;
  final ImportedRepositoryContext context;
  final ImportedAdvisoryStore store;
  final ProviderFactory _createProvider;
  final Duration requestLimit, cleanupLimit;
  static ImportedAdvisoryController? _owner;
  bool ready = false,
      busy = false,
      confirming = false,
      saving = false,
      cleanupUncertain = false;
  String? error;
  String draft = '';
  ImportedAdvisoryRecord? saved, unsaved;
  Map<String, String?>? _inputs;
  ModelProvider? _provider;
  StreamSubscription<String>? _subscription;
  Completer<void>? _done;
  Future<void>? _closing;
  bool _closeSettled = false, _stopped = false;
  bool get canRetryStop =>
      cleanupUncertain || (_owner?.isDisposed == true && _owner?.busy == false);
  bool get canAsk =>
      ready && !isDisposed && !busy && !cleanupUncertain && unsaved == null;

  void load() {
    if (isDisposed || busy || unsaved != null || cleanupUncertain) return;
    try {
      saved = store.load(inspection.root);
      ready = true;
      error = null;
    } catch (_) {
      ready = false;
      error = 'Saved advisory answer could not be loaded. Previous data has not been overwritten.';
    }
    update();
  }

  void _alive() {
    if (isDisposed || _stopped) {
      throw StateError('Advisory request no longer active.');
    }
  }

  Future<void> ask(
    String question, {
    required Future<bool> Function(ImportedAdvisoryRequest) confirm,
  }) async {
    if (!canAsk) return;
    if (_owner != null) {
      error = 'Another imported advisory request still owns its app connection. Stop or wait for it.';
      update();
      return;
    }
    _owner = this;
    busy = true;
    confirming = true;
    _stopped = false;
    error = null;
    draft = '';
    update();
    try {
      _alive();
      final prepared = store.prepare(inspection, context, question, saved);
      _inputs = prepared.inputs;
      if (!await confirm(prepared.request)) return;
      _alive();
      await store.authorize(prepared.inputs, _alive);
      _alive();
      confirming = false;
      update();
      _alive();
      final provider = _createProvider(prepared.request.config);
      _provider = provider;
      update();
      _alive();
      store.requireInputs(prepared.inputs);
      final completed = Completer<void>();
      _done = completed;
      final buffer = StringBuffer();
      _subscription = provider
          .generate(prepared.request.prompt)
          .listen(
            (text) {
              if (isDisposed || _stopped || completed.isCompleted) return;
              if (text.length >
                  ImportedAdvisoryRecord.answerLimit - buffer.length) {
                completed.completeError(
                  StateError('Advisory answer exceeded limit.'),
                );
                return;
              }
              buffer.write(text);
              draft = buffer.toString();
              update();
            },
            onError: (Object _, StackTrace _) {
              if (!completed.isCompleted) {
                completed.completeError(
                  StateError('Advisory transport failed.'),
                );
              }
            },
            onDone: () {
              if (!completed.isCompleted) completed.complete();
            },
          );
      await completed.future.timeout(requestLimit);
      _alive();
      store.requireInputs(prepared.inputs);
      final identity = provider is ModelResponseIdentityProvider
          ? provider.completedResponseModel
          : null;
      if (identity != prepared.request.config.model) {
        throw StateError('Advisory response identity is unavailable.');
      }
      unsaved = ImportedAdvisoryRecord.complete(
        prepared.request,
        buffer.toString(),
        identity!,
      );
      draft = '';
      await _persist();
    } catch (_) {
      if (!isDisposed && !_stopped) {
        error = unsaved == null
            ? 'Advisory request failed or inputs changed. Check the captured context, local model, limits and response identity, then retry. Previous saved answer remains.'
            : 'Answer completed but could not be saved. Previous saved answer remains. Retry saving without another model request.';
      }
    } finally {
      if (_done?.isCompleted == false) _done!.complete();
      _done = null;
      confirming = false;
      draft = '';
      await _cleanup();
      if (!cleanupUncertain && identical(_owner, this)) _owner = null;
      busy = false;
      saving = false;
      if (!isDisposed) update();
    }
  }

  Future<void> _persist() async {
    _alive();
    saving = true;
    update();
    _alive();
    final record = unsaved!;
    await store.save(record, _inputs!, _alive);
    if (!isDisposed) {
      saved = record;
      unsaved = null;
      error = null;
    }
    saving = false;
  }

  Future<void> retrySaving() async {
    if (isDisposed || busy || cleanupUncertain || unsaved == null) return;
    busy = true;
    error = null;
    update();
    try {
      await _persist();
    } catch (_) {
      if (!isDisposed) error = 'Answer could not be saved. Inputs may have changed; previous saved data remains. The completed answer is retained here.';
    } finally {
      if (!isDisposed) {
        busy = false;
        saving = false;
        update();
      }
    }
  }

  void stop() {
    if (isDisposed || !busy || saving) return;
    _stopped = true;
    draft = '';
    error = 'Stopped. Partial answer discarded; saved answer retained. Server inference may continue.';
    if (_done?.isCompleted == false) _done!.complete();
    update();
  }

  Future<void> _cleanup() async {
    final p = _provider, s = _subscription;
    if (p == null && s == null) return;
    if (_closing == null) {
      _closeSettled = false;
      _closing =
          Future.wait<void>([
            if (p != null) Future<void>.sync(p.cancel),
            if (s != null) Future<void>.sync(s.cancel),
          ]).then<void>(
            (_) {
              _closeSettled = true;
            },
            onError: (Object e, StackTrace st) {
              _closeSettled = true;
              Error.throwWithStackTrace(e, st);
            },
          );
    }
    try {
      await _closing!.timeout(cleanupLimit);
      _provider = null;
      _subscription = null;
      _closing = null;
      cleanupUncertain = false;
    } catch (_) {
      if (_closeSettled) _closing = null;
      cleanupUncertain = true;
      if (!isDisposed) error = 'App connection cleanup is unconfirmed. Retry Stop before another advisory request. Server inference may continue.';
    }
  }

  Future<void> retryStop() async {
    if (isDisposed || busy || !canRetryStop) return;
    final owner = cleanupUncertain ? this : _owner!;
    busy = true;
    update();
    await owner._cleanup();
    if (!owner.cleanupUncertain && identical(_owner, owner)) {
      _owner = null;
      if (!isDisposed) error = unsaved == null ? null : 'Completed answer retained. Retry saving without another model request.';
    }
    if (!isDisposed) {
      busy = false;
      update();
    }
  }

  void discardUnsaved() {
    if (isDisposed || busy || cleanupUncertain) return;
    unsaved = null;
    _inputs = null;
    error = null;
    update();
  }

  @override
  void dispose() {
    _stopped = true;
    if (_done?.isCompleted == false) _done!.complete();
    // A pending dialog has no app connection; stale consent cannot dispatch.
    if (_provider == null && identical(_owner, this)) _owner = null;
    // The owning ask retains any connection lease until cleanup settles.
    if (!busy) {
      unawaited(
        _cleanup().then((_) {
          if (!cleanupUncertain && identical(_owner, this)) _owner = null;
        }),
      );
    }
    super.dispose();
  }
}
