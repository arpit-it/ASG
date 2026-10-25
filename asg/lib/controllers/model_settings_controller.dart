import '../models/local_model_config.dart';
import '../services/model_settings_store.dart';
import '../services/local_model.dart';
import '../services/model_provider.dart';
import 'base_controller.dart';

class ModelSettingsController extends BaseController {
  ModelSettingsController(this.store, {ProviderFactory? createProvider})
    : _createProvider =
          createProvider ?? ((config) => LocalModelProvider(config));
  final ModelSettingsStore store;
  final ProviderFactory _createProvider;
  ModelProvider? _provider;
  LocalModelConfig get initial => store.load();
  String status =
      'Qwen 9B selected as the initial model family. Confirm the exact server model ID before testing.';
  bool busy = false;
  Future<void> save(LocalModelConfig config) async {
    if (busy || isDisposed) return;
    busy = true;
    update();
    try {
      await store.save(config);
      status = 'Settings saved. Model availability has not been verified.';
    } catch (e) {
      status = '$e';
    } finally {
      busy = false;
      update();
    }
  }

  Future<void> test(LocalModelConfig config) async {
    if (busy || isDisposed) return;
    busy = true;
    status = 'Waiting for the local model…';
    update();
    try {
      _provider = _createProvider(config);
      final result = await _provider!
          .generate(
            'Reply with one short sentence confirming you can help plan a software project.',
          )
          .join();
      status = 'Local server responded:\n$result';
    } catch (e) {
      status = 'Connection test failed: $e';
    } finally {
      await _provider?.cancel();
      _provider = null;
      busy = false;
      update();
    }
  }

  @override
  void dispose() {
    _provider?.cancel();
    super.dispose();
  }
}
