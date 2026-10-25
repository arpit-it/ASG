import '../models/chat_message.dart';
import '../models/project.dart';
import '../models/generation_event.dart';
import '../services/conversation_store.dart';
import '../services/model_settings_store.dart';
import '../services/local_model.dart';
import '../services/model_provider.dart';
import 'base_controller.dart';

class ChatController extends BaseController {
  ChatController(
    this.project, {
    Future<ConversationStore> Function()? openStore,
    ProviderFactory? createProvider,
  }) : _openStore = openStore ?? ConversationStore.open,
       _createProvider =
           createProvider ?? ((config) => LocalModelProvider(config));
  final StudioProject project;
  final Future<ConversationStore> Function() _openStore;
  final ProviderFactory _createProvider;
  ConversationStore? _store;
  ModelProvider? _provider;
  List<ChatMessage> _messages = [];
  List<ChatMessage> get messages => List.unmodifiable(_messages);
  GenerationPhase phase = GenerationPhase.idle;
  String draftResponse = '';
  bool cancelled = false;
  void cancelGeneration() {
    cancelled = true;
    phase = GenerationPhase.cancelling;
    _provider?.cancel();
    update();
  }

  bool busy = false;
  bool get ready => _store != null;
  String? error;
  Future<void> load() async {
    try {
      final store = await _openStore();
      final saved = store.load(project.id);
      if (isDisposed) return;
      _store = store;
      _messages = saved;
    } catch (_) {
      error = 'Conversation could not be loaded. Saved data has not been overwritten.';
    }
    update();
  }

  Future<bool> send(String prompt) async {
    final text = prompt.trim();
    if (text.isEmpty || busy || !ready || isDisposed) return false;
    busy = true;
    cancelled = false;
    phase = GenerationPhase.thinking;
    draftResponse = '';
    error = null;
    update();
    bool accepted = false;
    try {
      final updated = [..._messages, ChatMessage(role: 'user', content: text)];
      await _store!.save(project.id, updated);
      if (isDisposed) return false;
      _messages = updated;
      accepted = true;
      update();
      _provider = _createProvider(
        ModelSettingsStore(_store!.preferences).load(),
      );
      final recent = _messages
          .skip(_messages.length > 8 ? _messages.length - 8 : 0)
          .map((m) => '${m.role}: ${m.content}')
          .join('\n');
      final prompt =
          'Discuss requirements for this software project. You have no file or command tools; do not claim changes or tests were performed.\nProject: ${project.name}\nDescription: ${project.description}\nRecent conversation:\n$recent\nAssistant:';
      final buffer = StringBuffer();
      final activeProvider = _provider!;
      if (activeProvider is StreamingModelProvider) {
        await for (final event in activeProvider.generateEvents(prompt)) {
          if (isDisposed || cancelled) break;
          phase = event.phase;
          if (event.text.isNotEmpty) {
            buffer.write(event.text);
            draftResponse = buffer.toString();
          }
          update();
        }
      } else {
        await for (final text in activeProvider.generate(prompt)) {
          if (isDisposed || cancelled) break;
          phase = GenerationPhase.writing;
          buffer.write(text);
          draftResponse = buffer.toString();
          update();
        }
      }
      if (cancelled) return accepted;
      final result = buffer.toString();
      if (isDisposed) return accepted;
      final completed = [
        ..._messages,
        ChatMessage(role: 'assistant', content: result),
      ];
      await _store!.save(project.id, completed);
      if (!isDisposed) _messages = completed;
    } catch (e) {
      error = '$e';
    } finally {
      await _provider?.cancel();
      _provider = null;
      busy = false;
      phase = GenerationPhase.idle;
      draftResponse = '';
      update();
    }
    return accepted;
  }

  @override
  void dispose() {
    _provider?.cancel();
    super.dispose();
  }
}
