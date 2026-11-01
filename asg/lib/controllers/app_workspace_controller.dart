// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/app_definition.dart';
import '../models/chat_message.dart';
import '../models/project.dart';
import '../models/generation_event.dart';
import '../services/application_store.dart';
import '../services/application_editor.dart';
import '../services/model_settings_store.dart';
import '../services/record_storage.dart';
import 'base_controller.dart';

class AppWorkspaceController extends BaseController {
  AppWorkspaceController(
    this.project, {
    Future<ApplicationStore> Function()? openStore,
    ApplicationEditor? editor,
  }) : _openStore = openStore ?? ApplicationStore.open,
       _editor = editor ?? ApplicationEditor();
  final StudioProject project;
  final Future<ApplicationStore> Function() _openStore;
  final ApplicationEditor _editor;
  ApplicationStore? _store;
  RecordStorage? get records => _store?.records;
  ApplicationSnapshot? _state;
  AppDefinition? _runtimeDefinition;
  Future<bool>? _interactionWrite;
  bool get savingInteractions => _interactionWrite != null;
  bool get hasUnsavedInteractions => _runtimeDefinition != null;

  Future<void> recordRuntimeState(AppDefinition value) async {
    if (_busy || isDisposed || _state == null) return;
    _runtimeDefinition = value;
    await saveInteractions();
  }

  Future<bool> saveInteractions() {
    final active = _interactionWrite;
    if (active != null) return active;
    final future = _flushInteractions().whenComplete(() {
      _interactionWrite = null;
      update();
    });
    _interactionWrite = future;
    update();
    return future;
  }

  Future<bool> _flushInteractions() async {
    while (_runtimeDefinition != null) {
      final definition = _runtimeDefinition!;
      final current = _state;
      final store = _store;
      if (current == null || store == null) return false;
      try {
        final snapshot = ApplicationSnapshot(
          definition,
          current.messages,
          current.revision,
        );
        await store.save(project.id, snapshot);
        _state = snapshot;
        if (identical(_runtimeDefinition, definition)) {
          _runtimeDefinition = null;
        }
        _error = null;
      } catch (_) {
        if (!isDisposed) {
          _error =
              'Preview changes are not saved. Check local storage and Retry saving '
              'before leaving this project. Your pending preview changes remain available.';
        }
        return false;
      }
    }
    return true;
  }

  AppDefinition? get definition => _runtimeDefinition ?? _state?.definition;
  List<ChatMessage> get messages => List.unmodifiable(_state?.messages ?? []);
  int get revision => _state?.revision ?? 0;
  GenerationPhase _phase = GenerationPhase.idle;
  GenerationPhase get phase => _phase;
  String _draftResponse = '';
  String get draftResponse => _draftResponse;
  String? _pendingInstruction;
  String? get pendingInstruction => _pendingInstruction;
  bool _cancelRequested = false;
  void cancelGeneration() {
    if (!_busy) return;
    _cancelRequested = true;
    _phase = GenerationPhase.cancelling;
    _editor.cancel();
    update();
  }

  bool _busy = false;
  bool get busy => _busy;
  String? _error;
  String? get error => _error;
  Future<void> load() async {
    try {
      final store = await _openStore();
      final loaded = store.load(project);
      if (isDisposed) return;
      _store = store;
      _state = loaded;
      _error = null;
    } catch (_) {
      if (!isDisposed) {
        _error =
            'Application could not be restored. Check local storage and reopen '
            'the project to retry. Saved records have not been replaced.';
      }
    }
    update();
  }

  Future<bool> apply(String instruction) async {
    final text = instruction.trim();
    final store = _store;
    if (_busy ||
        _state == null ||
        store == null ||
        text.isEmpty ||
        isDisposed) {
      return false;
    }
    _busy = true;
    _phase = GenerationPhase.applying;
    update();
    if (!await saveInteractions() || isDisposed) {
      _busy = false;
      _phase = GenerationPhase.idle;
      update();
      return false;
    }
    final current = _state!;
    _cancelRequested = false;
    _phase = GenerationPhase.thinking;
    _draftResponse = '';
    _pendingInstruction = text;
    _error = null;
    update();
    try {
      final change = await _editor.apply(
        ModelSettingsStore(store.records).load(),
        _runtimeDefinition ?? current.definition,
        text,
        onProgress: (event) {
          if (isDisposed || _cancelRequested) return;
          _phase = event.phase;
          if (event.text.isNotEmpty) _draftResponse = event.text;
          update();
        },
      );
      if (_cancelRequested) return false;
      if (isDisposed) return false;
      final updated = ApplicationSnapshot(change.definition, [
        ...current.messages,
        ChatMessage(role: 'user', content: text),
        ChatMessage(
          role: 'assistant',
          content: change.summary,
          modelRequest: change.modelRequest,
        ),
      ], current.revision + 1);
      _phase = GenerationPhase.applying;
      update();
      await store.save(project.id, updated);
      if (isDisposed) return false;
      _state = updated;
      _runtimeDefinition = null;
      return true;
    } catch (_) {
      if (!isDisposed) {
        _error = _cancelRequested
            ? 'Generation cancelled. Your last working version is unchanged.'
            : 'Update could not be applied. Your last working version is unchanged. '
                  'Check the model connection and local storage, then retry the instruction.';
      }
      return false;
    } finally {
      _busy = false;
      _phase = GenerationPhase.idle;
      _pendingInstruction = null;
      _draftResponse = '';
      update();
    }
  }

  @override
  void dispose() {
    _editor.cancel();
    super.dispose();
  }
}
