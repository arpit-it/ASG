import '../models/app_definition.dart';
import '../models/chat_message.dart';
import '../models/project.dart';
import '../models/generation_event.dart';
import '../services/application_store.dart';
import '../services/application_editor.dart';
import '../services/model_settings_store.dart';
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
  ApplicationSnapshot? _state;
  AppDefinition? _runtimeDefinition;
  void recordRuntimeState(AppDefinition value) {
    if (!_busy && !isDisposed) _runtimeDefinition = value;
  }

  AppDefinition? get definition => _state?.definition;
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
    } catch (e) {
      _error = 'Application could not be restored: $e';
    }
    update();
  }

  Future<bool> apply(String instruction) async {
    final text = instruction.trim();
    final current = _state;
    final store = _store;
    if (_busy ||
        current == null ||
        store == null ||
        text.isEmpty ||
        isDisposed) {
      return false;
    }
    _busy = true;
    _cancelRequested = false;
    _phase = GenerationPhase.thinking;
    _draftResponse = '';
    _pendingInstruction = text;
    _error = null;
    update();
    try {
      final change = await _editor.apply(
        ModelSettingsStore(store.preferences).load(),
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
        ChatMessage(role: 'assistant', content: change.summary),
      ], current.revision + 1);
      _phase = GenerationPhase.applying;
      update();
      await store.save(project.id, updated);
      if (isDisposed) return false;
      _state = updated;
      _runtimeDefinition = null;
      return true;
    } catch (e) {
      _error = _cancelRequested
          ? 'Generation cancelled. Your last working version is unchanged.'
          : 'Update could not be applied. Your last working version is unchanged. $e';
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
