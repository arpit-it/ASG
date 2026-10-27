import 'dart:async';

import '../models/local_model_config.dart';
import '../models/runtime_setup.dart';
import '../services/model_provider.dart';
import '../services/model_settings_store.dart';
import '../services/runtime_setup_store.dart';
import '../services/runtime_connection.dart';
import '../services/runtime_host.dart';
import 'base_controller.dart';
import 'model_settings_controller.dart';

class RuntimeSetupController extends BaseController {
  RuntimeSetupController({
    required this.store,
    required this.modelStore,
    required this.host,
    RuntimeConnection? connection,
    ProviderFactory? createProvider,
  }) : connection = connection ?? RuntimeConnection(),
       _probe = ModelSettingsController(
         modelStore,
         createProvider: createProvider,
       ) {
    _probe.addListener(_probeChanged);
  }
  final RuntimeSetupStore store;
  final ModelSettingsStore modelStore;
  final RuntimeHost host;
  final RuntimeConnection connection;
  RuntimeSetup _setup = const RuntimeSetup();
  RuntimeSetup get setup => _setup;
  LocalModelConfig _connectionConfig = const LocalModelConfig();
  LocalModelConfig get connectionConfig => _connectionConfig;
  List<ModelCandidate> _candidates = [];
  List<ModelCandidate> get candidates => List.unmodifiable(_candidates);
  ModelCandidate? _selected;
  ModelCandidate? get selected => _selected;
  final List<String> _logs = [];
  List<String> get logs => List.unmodifiable(_logs);
  RuntimeHealth _health = const RuntimeHealth(
    ready: false,
    detail: 'Checking runtime…',
  );
  RuntimeHealth get health => _health;
  bool _busy = false, _checking = false, _stopRequested = false;
  bool get busy => _busy || host.working;
  String? _error;
  String? get error => _error;
  String _status = 'Choose local model files or download a repository.';
  String get status => _status;
  Timer? _timer;
  StreamSubscription<String>? _subscription;
  final ModelSettingsController _probe;
  bool get testing => _probe.testing;
  static const requestLimits = ModelSettingsController.requestLimits;

  void _probeChanged() {
    if (isDisposed) return;
    _status = _probe.status;
    update();
  }

  void stopTest() => _probe.stopTest();
  void initialize() {
    try {
      _setup = store.load();
      _connectionConfig = modelStore.load();
    } catch (e) {
      _error = 'Saved runtime settings could not be loaded: $e';
    }
    _subscription = host.events.listen((line) {
      _logs.add(line);
      if (_logs.length > 60) _logs.removeAt(0);
      update();
    });
    unawaited(refresh());
    _timer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(refresh()),
    );
  }

  Future<void> refresh() async {
    if (_checking || isDisposed) return;
    _checking = true;
    try {
      final result = await connection.check(_connectionConfig);
      if (!isDisposed) _health = result;
    } finally {
      _checking = false;
      update();
    }
  }

  Future<void> _action(Future<void> Function() operation) async {
    if (busy || isDisposed) return;
    _busy = true;
    _error = null;
    update();
    try {
      await operation();
    } catch (e) {
      _error = '$e';
    } finally {
      _busy = false;
      update();
    }
  }

  Future<String?> chooseDirectory() async {
    try {
      return await host.chooseDirectory();
    } catch (e) {
      _error = '$e';
      update();
      return null;
    }
  }

  Future<String?> choosePython() async {
    try {
      return await host.choosePython();
    } catch (e) {
      _error = '$e';
      update();
      return null;
    }
  }

  Future<void> inspect(String path) => _action(() async {
    final found = await host.scan(path);
    if (isDisposed) return;
    _candidates = found;
    _selected = null;
    for (final item in found) {
      if (item.supported) {
        _selected = item;
        break;
      }
    }
    _status =
        '${found.length} model folder(s) found. Select a compatible checkpoint.';
  });
  void select(ModelCandidate value) {
    if (!busy && value.supported) {
      _selected = value;
      update();
    }
  }

  Future<void> prepare(String python) => _action(() async {
    _status = 'Checking Python and preparing the helper…';
    update();
    await host.prepare(python.trim());
    _status = 'Runtime helper ready. You can start the selected model.';
  });
  Future<void> download(RuntimeSetup values) => _action(() async {
    ModelRepository.parse(values.repository);
    await store.save(values);
    _setup = values;
    _status = 'Downloading model artifacts. This may be a large transfer; see the log.';
    update();
    final path = await host.download(values);
    final found = await host.scan(path);
    if (isDisposed) return;
    _candidates = found;
    _selected = null;
    for (final item in found) {
      if (item.supported) {
        _selected = item;
        break;
      }
    }
    _status =
        'Download complete. Check compatibility before starting inference.';
  });
  bool get _startupCancelled => isDisposed || _stopRequested;

  Future<void> start(RuntimeSetup values) => _action(() async {
    _stopRequested = false;
    final candidate = _selected;
    if (candidate == null || !candidate.supported) {
      throw StateError('Scan and select a compatible checkpoint first.');
    }
    if (_health.ready) {
      throw StateError(
        'A runtime is already running. Use it or stop it before starting another. Externally started runtimes must be stopped in their terminal.',
      );
    }
    _loadChatCeiling();
    // Revalidate immediately before launch, in case files changed after scanning.
    final validated = await host.scan(candidate.path);
    if (_startupCancelled) return;
    if (!validated.any((m) => m.path == candidate.path && m.supported)) {
      throw StateError('Selected checkpoint is no longer valid.');
    }
    final saved = RuntimeSetup(
      python: values.python.trim(),
      modelPath: candidate.path,
      repository: values.repository,
      downloadParent: values.downloadParent,
      revision: values.revision,
    );
    await store.save(saved);
    if (_startupCancelled) return;
    _setup = saved;
    final config = LocalModelConfig(
      baseUrl: 'http://127.0.0.1:8765/v1',
      model: candidate.name,
    );
    await host.start(saved, candidate.name);
    if (_startupCancelled) {
      // Stop may have run before the asynchronous launch acquired its process.
      if (_stopRequested && host.ownsProcess) await host.stop();
      return;
    }
    // Persist chat configuration only after the runtime reports the selected path.
    _status = 'Loading selected model…';
    update();
    final deadline = DateTime.now().add(const Duration(minutes: 3));
    while (!_startupCancelled &&
        host.ownsProcess &&
        DateTime.now().isBefore(deadline)) {
      final result = await connection.check(config);
      if (_startupCancelled) return;
      if (!host.ownsProcess) break;
      if (result.ready &&
          result.model == candidate.name &&
          result.modelPath == candidate.path) {
        final savedConfig = await _saveConnection(config);
        if (_startupCancelled) return;
        if (!host.ownsProcess) break;
        _connectionConfig = savedConfig;
        _health = result;
        _status = 'Runtime ready. Project chat now uses ${candidate.name}.';
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    if (isDisposed || _stopRequested) return;
    throw StateError(
      host.ownsProcess
          ? 'Model is still loading. Refresh status; Stop is available if needed.'
          : 'Runtime exited before becoming ready. Inspect the log and Python environment.',
    );
  });
  Future<void> stop() async {
    // Stop remains available during startup; it targets only the owned process.
    try {
      _stopRequested = true;
      await host.stop();
      _status = 'Managed runtime stopped.';
      await refresh();
    } catch (e) {
      _error = '$e';
    }
    update();
  }

  Future<void> connect(LocalModelConfig config) => _action(() async {
    config.endpoint;
    _loadChatCeiling();
    final result = await connection.check(config);
    if (!result.ready || result.model != config.model) {
      throw StateError(
        'No ready runtime reporting this model ID. Check the URL and model ID.',
      );
    }
    _connectionConfig = await _saveConnection(config);
    _health = result;
    _status = 'Connected. Project chat uses ${config.model}.';
  });
  int _loadChatCeiling() {
    try {
      return modelStore.load().chatOutputTokens;
    } catch (_) {
      throw StateError(
        'Saved model settings could not be loaded. Restore valid settings before connecting or starting a model. Records have not been overwritten.',
      );
    }
  }

  Future<LocalModelConfig> _saveConnection(LocalModelConfig config) async {
    // Setup changes only the connection. Reload at save time to retain settings
    // changed during health verification or model loading.
    final saved = LocalModelConfig(
      baseUrl: config.baseUrl,
      model: config.model,
      chatOutputTokens: _loadChatCeiling(),
    );
    await modelStore.save(saved);
    return saved;
  }

  Future<void> test(LocalModelConfig config) => _action(() async {
    await _probe.test(config);
  });
  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_subscription?.cancel());
    _probe.removeListener(_probeChanged);
    _probe.dispose();
    connection.close();
    super.dispose();
  }
}
