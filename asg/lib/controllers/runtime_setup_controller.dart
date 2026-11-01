// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';

import '../models/local_model_config.dart';
import '../models/cpu_checkpoint_inspection.dart';
import '../models/model_download.dart';
import '../services/model_download_host.dart';
import '../models/model_catalog.dart';
import '../models/runtime_setup.dart';
import '../models/runtime_capabilities.dart';
import '../services/model_hardware.dart';
import '../services/model_provider.dart';
import '../services/model_settings_store.dart';
import '../services/runtime_setup_store.dart';
import '../services/runtime_connection.dart';
import '../services/runtime_host.dart';
import '../services/cpu_checkpoint_inspection_host.dart';
import '../services/cpu_environment_preparation_host.dart';
import '../services/cpu_runtime_launch_host.dart';
import 'base_controller.dart';
import 'model_settings_controller.dart';

class RuntimeSetupController extends BaseController {
  RuntimeSetupController({
    required this.store,
    required this.modelStore,
    required this.host,
    RuntimeConnection? connection,
    ProviderFactory? createProvider,
    Future<ModelHardware> Function()? inspectMemory,
  }) : inspectMemory = inspectMemory ?? probeModelHardware,
       connection = connection ?? RuntimeConnection(),
       _probe = ModelSettingsController(
         modelStore,
         createProvider: createProvider,
       ) {
    _probe.addListener(_probeChanged);
  }
  final RuntimeSetupStore store;
  final ModelSettingsStore modelStore;
  final RuntimeHost host;
  final Future<ModelHardware> Function() inspectMemory;
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
  bool _busy = false, _stopRequested = false, _settingsLoadFailed = false;
  Object? _healthCheck;
  bool _cpuLaunching = false;
  bool get cpuLaunching => _cpuLaunching;
  bool get canLaunchCpuRuntime =>
      host.supported && host is CpuRuntimeLaunchHost;

  bool get busy => _busy || host.working;
  String? _error;
  String? get error => _error;
  String _status = 'Choose local model files or download a repository.';
  String get status => _status;
  ModelDownloadHost? get _transfer =>
      host is ModelDownloadHost ? host as ModelDownloadHost : null;
  ModelDownloadProgress get downloadProgress =>
      _transfer?.downloadProgress ?? const ModelDownloadProgress();
  bool get transferControls => _transfer != null;
  StreamSubscription<ModelDownloadProgress>? _downloadSubscription;
  Future<void> pauseDownload() async {
    await _transfer?.pauseDownload();
    update();
  }

  Future<void> stopDownload() async {
    await _transfer?.stopDownload();
    update();
  }

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
    } catch (_) {
      _settingsLoadFailed = true;
      _error = 'Saved runtime settings could not be loaded. Records have not been overwritten. Restore valid settings before continuing.';
    }
    _downloadSubscription = _transfer?.downloadEvents.listen((_) => update());
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

  /// Observe a known runtime identity without assigning repository provenance.
  /// Download source fields describe the next launch and may have changed.
  Future<RunningCatalogModel?> inspectRunningCatalogModel() async {
    final setup = _setup;
    final config = _connectionConfig;
    if (isDisposed || busy || _settingsLoadFailed) return null;
    final endpoint = config.endpoint;
    if (!['localhost', '127.0.0.1', '::1'].contains(endpoint.host)) return null;
    final result = await connection.check(config);
    if (isDisposed ||
        busy ||
        !identical(setup, _setup) ||
        !identical(config, _connectionConfig) ||
        !result.ready ||
        !result.idle ||
        result.loadedDevice != LoadedRuntimeDevice.mlxMetal ||
        setup.modelPath.isEmpty ||
        result.modelPath != setup.modelPath ||
        result.model != config.model) {
      return null;
    }
    return RunningCatalogModel(config.model);
  }

  Future<void> refresh() async {
    if (_healthCheck != null || isDisposed) return;
    final check = Object();
    _healthCheck = check;
    final checkedConfig = _connectionConfig;
    try {
      final result = await connection.check(checkedConfig);
      // A newly connected or started runtime owns its verified health. A late
      // poll of the previous connection must not replace that result.
      if (!isDisposed &&
          identical(check, _healthCheck) &&
          identical(checkedConfig, _connectionConfig)) {
        _health = result;
      }
    } finally {
      if (identical(check, _healthCheck)) _healthCheck = null;
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
      if (isDisposed) return;
      _error = '$e';
    } finally {
      _busy = false;
      update();
    }
  }

  Future<String?> chooseDirectory() async {
    if (isDisposed) return null;
    try {
      final path = await host.chooseDirectory();
      if (isDisposed) return null;
      _error = null;
      update();
      return path;
    } catch (_) {
      if (isDisposed) return null;
      _error = 'The model folder picker could not be opened. Try again and check that file selection is available on this device.';
      update();
      return null;
    }
  }

  Future<String?> choosePython() async {
    if (isDisposed) return null;
    try {
      final path = await host.choosePython();
      if (isDisposed) return null;
      _error = null;
      update();
      return path;
    } catch (_) {
      if (isDisposed) return null;
      _error = 'The Python interpreter picker could not be opened. Try again and check that file selection is available on this device.';
      update();
      return null;
    }
  }

  Future<List<ModelCandidate>> _scan(String path) async {
    try {
      return await host.scan(path);
    } catch (_) {
      if (!isDisposed) _status = 'Model folder scan failed.';
      // Filesystem errors may embed private paths and host diagnostics.
      throw StateError(
        'Could not inspect model files. Check the selected folder and read '
        'permissions, then retry the scan.',
      );
    }
  }

  Future<void> inspect(String path) => _action(() async {
    invalidateCapabilities();
    final found = await _scan(path);
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
      invalidateCapabilities();
      _selected = value;
      update();
    }
  }

  ModelHardware? _memory;
  ModelHardware? get memory => _memory;
  RuntimeCapabilities? _capabilities;
  RuntimeCapabilities? get capabilities => _capabilities;
  CpuCheckpointInspection? _cpuCheckpointInspection;
  CpuCheckpointInspection? get cpuCheckpointInspection =>
      _cpuCheckpointInspection;
  bool get canInspectCpuCheckpoint =>
      host.supported && host is CpuCheckpointInspectionHost;
  int _discoveryEpoch = 0;

  void invalidateCapabilities() {
    _discoveryEpoch++;
    _capabilities = null;
    _memory = null;
    _cpuCheckpointInspection = null;
    update();
  }

  Future<void> discover(String python) => _action(() async {
    invalidateCapabilities();
    final epoch = _discoveryEpoch;
    _status = 'Inspecting host, dependencies and device availability without loading weights…';
    update();
    try {
      final report = await host.discover(python.trim());
      if (isDisposed || epoch != _discoveryEpoch) return;
      // A memory-only failure must not discard useful dependency/device results.
      ModelHardware memory;
      try {
        memory = await inspectMemory();
      } catch (_) {
        memory = const ModelHardware(appleSilicon: false);
      }
      if (isDisposed || epoch != _discoveryEpoch) return;
      _capabilities = report;
      _memory = memory;
      _status = 'Host, dependency and device inspection complete. Model loading and memory adequacy remain unverified.';
    } catch (_) {
      if (isDisposed || epoch != _discoveryEpoch) return;
      _status = 'Capability discovery failed.';
      throw StateError(
        'Could not inspect runtime capabilities. Check the selected Python interpreter and installed packages, then retry. No weights were loaded or settings changed.',
      );
    }
  });

  /// Structural observation. Call invalidateCapabilities when input
  /// context changes; observations never establish compatibility or readiness.
  Future<void> inspectCpuCheckpoint(
    String python,
    String modelPath, {
    required bool experimentalCpu,
    int? maxWeightBytes,
  }) => _action(() async {
    if (!experimentalCpu ||
        python.trim().isEmpty ||
        modelPath.trim().isEmpty ||
        (maxWeightBytes != null &&
            (maxWeightBytes < 1 || maxWeightBytes > 9007199254740991))) {
      throw const FormatException(
        'Explicit experimental CPU consent, Python, checkpoint and a valid optional disk-byte ceiling are required.',
      );
    }
    final target = host;
    if (!target.supported || target is! CpuCheckpointInspectionHost) {
      throw StateError(
        'Experimental CPU checkpoint inspection is unavailable on this host.',
      );
    }
    invalidateCapabilities();
    final epoch = _discoveryEpoch;
    _status = 'Inspecting experimental CPU checkpoint structure and disk bytes without loading weights…';
    update();
    try {
      final report = await (target as CpuCheckpointInspectionHost)
          .inspectCpuCheckpoint(
            python.trim(),
            modelPath.trim(),
            experimentalCpu: true,
            maxWeightBytes: maxWeightBytes,
          );
      if (isDisposed || epoch != _discoveryEpoch) return;
      _cpuCheckpointInspection = report;
      _status =
          'Experimental CPU checkpoint inspected. ${CpuCheckpointInspection.scope}';
    } catch (_) {
      if (isDisposed || epoch != _discoveryEpoch) return;
      _status = 'Experimental CPU checkpoint inspection failed.';
      throw StateError(
        'Could not inspect the experimental CPU checkpoint. Check Python, '
        'checkpoint structure, read permissions and the optional disk-byte ceiling, '
        'then retry. Inference and memory adequacy remain unverified.',
      );
    }
  });

  Future<void> prepare(
    String python, {
    RuntimeBackend backend = RuntimeBackend.auto,
  }) => _action(() async {
    invalidateCapabilities();
    _status = 'Checking Python and preparing the helper…';
    update();
    try {
      await host.prepare(python.trim(), backend: backend);
    } catch (_) {
      if (isDisposed) return;
      _status = 'Runtime helper preparation failed.';
      // Host errors may contain private filesystem paths or process arguments.
      throw StateError(
        'Could not prepare the runtime helper. Check the selected Python '
        'interpreter, required packages and local storage permissions, then retry.',
      );
    }
    if (isDisposed) return;
    _status =
        'Runtime helper ready for ${backend.label}. Model loading and memory adequacy remain unverified.';
  });

  bool get canPrepareCpuEnvironment =>
      host.supported && host is CpuEnvironmentPreparationHost;

  /// Explicit opt-in; preparation never establishes CPU inference support.
  Future<void> prepareCpuEnvironment(
    String python, {
    required bool experimentalCpu,
  }) => _action(() async {
    if (!experimentalCpu || python.trim().isEmpty) {
      throw const FormatException(
        'Choose Python and explicitly consent to experimental CPU preparation.',
      );
    }
    final target = host;
    if (!target.supported || target is! CpuEnvironmentPreparationHost) {
      throw StateError(
        'Experimental CPU preparation is unavailable on this host.',
      );
    }
    invalidateCapabilities();
    _status = 'Checking installed experimental CPU dependencies without loading weights…';
    update();
    try {
      await (target as CpuEnvironmentPreparationHost).prepareCpuEnvironment(
        python.trim(),
        experimentalCpu: true,
      );
    } catch (_) {
      if (isDisposed) return;
      _status = 'Experimental CPU preparation failed.';
      throw StateError(
        'Could not check experimental CPU dependencies. Check the selected Python '
        'interpreter, installed Torch, Transformers and safetensors, then retry. '
        'Model loading and memory adequacy remain unverified.',
      );
    }
    if (isDisposed) return;
    _status =
        'Experimental CPU dependencies checked. Model loading, memory '
        'adequacy and inference remain unverified. Connection settings are unchanged.';
  });

  /// Launch-only opt-in for controlled CPU validation. Does not save settings,
  /// connect chat, or establish model readiness or real-host inference support.
  Future<void> startCpuRuntime(
    RuntimeSetup values,
    String modelId, {
    required bool experimentalCpu,
    int threads = 2,
    int? maxWeightBytes,
    Duration loadTimeout = const Duration(seconds: 180),
  }) => _action(() async {
    if (!experimentalCpu ||
        values.python.trim().isEmpty ||
        values.modelPath.trim().isEmpty ||
        modelId.trim().isEmpty ||
        threads < 1 ||
        threads > 32 ||
        (maxWeightBytes != null &&
            (maxWeightBytes < 1 || maxWeightBytes > 9007199254740991)) ||
        loadTimeout <= Duration.zero ||
        loadTimeout > const Duration(hours: 1)) {
      throw const FormatException(
        'Explicit experimental CPU consent, Python, checkpoint, model ID and valid CPU limits are required.',
      );
    }
    final target = host;
    if (!target.supported || target is! CpuRuntimeLaunchHost) {
      throw StateError('Experimental CPU launch is unavailable on this host.');
    }
    if (_health.ready || host.ownsProcess) {
      throw StateError(
        'A runtime is already running. Stop it before an experimental CPU launch.',
      );
    }
    _stopRequested = false;
    invalidateCapabilities();
    _cpuLaunching = true;
    _status = 'Starting experimental CPU process…';
    update();
    try {
      await (target as CpuRuntimeLaunchHost).startCpuRuntime(
        RuntimeSetup(
          python: values.python.trim(),
          modelPath: values.modelPath.trim(),
        ),
        modelId.trim(),
        experimentalCpu: true,
        threads: threads,
        maxWeightBytes: maxWeightBytes,
        loadTimeout: loadTimeout,
      );
    } catch (_) {
      if (_startupCancelled) return;
      _status = 'Experimental CPU launch failed.';
      throw StateError(
        'Could not launch experimental CPU. Check Python, installed dependencies, '
        'checkpoint, limits and port, then retry. Stop an owned process before retrying.',
      );
    } finally {
      _cpuLaunching = false;
    }
    // Stop may precede asynchronous acquisition of the process. Disposal also
    // cleans a late process, without publishing completion to a closed view.
    if (_startupCancelled) {
      if (host.ownsProcess) await _stopManaged();
      return;
    }
    _status =
        'Experimental CPU launch requested. Verify health separately before '
        'connecting. Model readiness, memory adequacy and real-host inference '
        'remain unverified. Connection settings are unchanged.';
  });
  Future<void> saveSetup(RuntimeSetup values) => _action(() async {
    await _saveSetup(values);
    if (isDisposed) return;
    _setup = values;
    _status = 'Runtime setup saved for the next launch. The connected runtime is unchanged.';
  });

  Future<void> download(
    RuntimeSetup values, {
    bool resume = false,
  }) => _action(() async {
    invalidateCapabilities();
    ModelRepository.parse(values.repository);
    await _saveSetup(values);
    _setup = values;
    _status = 'Downloading model artifacts. This may be a large transfer; see the log.';
    update();
    final String path;
    try {
      path = resume && _transfer != null
          ? await _transfer!.resumeDownload(values)
          : await host.download(values);
    } on DownloadInterrupted {
      if (!isDisposed) {
        _status = downloadProgress.phase == DownloadPhase.paused
            ? 'Download paused. Partial files retained; Resume continues this revision.'
            : 'Download stopped. Partial files retained; Resume is available.';
      }
      return;
    } catch (_) {
      if (isDisposed) return;
      _status = 'Model download failed.';
      if (downloadProgress.problem != null) {
        throw StateError(downloadProgress.problem!);
      }
      // Host failures can embed private paths, repository URLs or arguments.
      throw StateError(
        'Could not download model files. Check the repository, revision, Python '
        'environment, network and destination permissions, then retry. Existing '
        'folders are retained; inspect downloaded files or choose a different '
        'destination if a partial folder already exists.',
      );
    }
    if (isDisposed) return;
    invalidateCapabilities();
    final found = await _scan(path);
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
    final validated = await _scan(candidate.path);
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
      backend: values.backend,
    );
    await _saveSetup(saved);
    if (_startupCancelled) return;
    _setup = saved;
    final config = LocalModelConfig(
      baseUrl: 'http://127.0.0.1:8765/v1',
      model: candidate.name,
    );
    try {
      await host.start(saved, candidate.name);
    } catch (_) {
      if (_startupCancelled) return;
      _status = 'Managed runtime launch failed.';
      // Process failures may include private interpreter paths and arguments.
      throw StateError(
        'Could not launch the managed runtime. Check the selected Python '
        'interpreter, required packages and local port availability, then retry. '
        'If a process started, Stop is available before retrying.',
      );
    }
    if (_startupCancelled) {
      // Stop may have run before the asynchronous launch acquired its process.
      // Reuse Stop's private failure/retry state for this late cleanup too.
      if (_stopRequested && host.ownsProcess) await _stopManaged();
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
    if (isDisposed) return;
    await _stopManaged();
  }

  Future<void> _stopManaged() async {
    if (!isDisposed) _error = null;
    try {
      _stopRequested = true;
      await host.stop();
      if (isDisposed) return;
      _status = 'Managed runtime stopped.';
      // Supersede pre-stop checks and immediately observe the stopped runtime.
      // Their late completion must not publish or release the new poll guard.
      _healthCheck = null;
      await refresh();
    } catch (_) {
      if (isDisposed) return;
      _status = 'Managed runtime stop failed.';
      _error = 'Could not stop the managed runtime. Check the local runtime process and retry Stop. Externally started runtimes must be stopped in their terminal.';
    }
    update();
  }

  Future<void> connect(LocalModelConfig config) => _action(() async {
    try {
      config.endpoint;
    } on FormatException {
      // URI parser exceptions can include the private input URL.
      throw const FormatException(
        'Invalid connection settings. Use a local HTTP URL without credentials, query or fragment and a nonempty model ID.',
      );
    }
    _loadChatCeiling();
    final result = await connection.check(config);
    if (isDisposed) return;
    if (!result.ready || result.model != config.model) {
      throw StateError(
        'No ready runtime reporting this model ID. Check the URL and model ID.',
      );
    }
    final savedConfig = await _saveConnection(config);
    // A write already dispatched before closure may complete; do not publish
    // state to the closed setup controller.
    if (isDisposed) return;
    _connectionConfig = savedConfig;
    _health = result;
    _status = 'Connected. Project chat uses ${config.model}.';
  });
  Future<void> _saveSetup(RuntimeSetup values) async {
    if (_settingsLoadFailed) {
      throw StateError(
        'Saved runtime settings are invalid. Restore valid settings and reopen setup before saving. Records have not been overwritten.',
      );
    }
    try {
      await store.save(values);
    } catch (_) {
      // Storage exceptions can include private paths or serialized setup data.
      throw StateError(
        'Runtime setup settings could not be saved. Check local storage and retry. '
        'No download or runtime launch was started.',
      );
    }
  }

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
    try {
      await modelStore.save(saved);
    } catch (_) {
      // Storage errors may contain private paths or serialized record content.
      throw StateError(
        'Connection settings could not be saved. Check local storage and retry. '
        'A started managed runtime can still be stopped with Stop.',
      );
    }
    return saved;
  }

  Future<void> test(LocalModelConfig config) => _action(() async {
    await _probe.test(config);
  });
  @override
  void dispose() {
    if (downloadProgress.active) unawaited(_transfer?.stopDownload());
    unawaited(_downloadSubscription?.cancel());
    _timer?.cancel();
    unawaited(_subscription?.cancel());
    _probe.removeListener(_probeChanged);
    _probe.dispose();
    connection.close();
    super.dispose();
  }
}
