// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';

import '../models/local_model_config.dart';
import '../models/model_connection_preset.dart';
import '../models/model_profile_notes.dart';
import '../models/model_format_probe.dart';
import '../models/model_test_observation.dart';
import '../models/model_runtime_metrics.dart';
import '../services/model_settings_store.dart';
import '../services/local_model.dart';
import '../services/model_inventory.dart';
import '../services/model_provider.dart';
import 'base_controller.dart';

class ModelSettingsController extends BaseController {
  ModelSettingsController(
    this.store, {
    ProviderFactory? createProvider,
    Duration Function()? elapsed,
    DateTime Function()? now,
    Future<String> Function(LocalModelConfig)? inspectInventory,
  }) : _now = now ?? DateTime.now,
       _elapsed = elapsed ?? _monotonicClock(),
       _inspectInventory = inspectInventory ?? ModelInventory.inspect,
       _createProvider =
           createProvider ?? ((config) => LocalModelProvider(config)) {
    try {
      _presets = store.loadPresets();
    } catch (_) {
      presetsLoadFailed = true;
      presetStatus = 'Saved connection presets could not be read. Records are preserved; restore valid presets before editing them.';
    }
  }
  final Future<String> Function(LocalModelConfig) _inspectInventory;
  String? inventoryStatus;
  ModelRuntimeMetrics? runtimeMetrics;

  static const draftChangedGuidance =
      'Connection draft changed. Test again to observe this draft; settings are unchanged.';

  void connectionDraftChanged() {
    if (busy || settingsLoadFailed || isDisposed) return;
    inventoryStatus = null;
    runtimeMetrics = null;
    _pendingObservation = null;
    _testedConfig = null;
    status = draftChangedGuidance;
    update();
  }

  void clearInventory() {
    if (inventoryStatus == null || isDisposed) return;
    inventoryStatus = null;
    update();
  }

  Future<void> inspectInventory(LocalModelConfig config) async {
    if (busy || settingsLoadFailed || isDisposed) return;
    busy = true;
    inventoryStatus = 'Checking draft model inventory (3 seconds maximum)…';
    update();
    try {
      final result = await _inspectInventory(config);
      if (!isDisposed) inventoryStatus = result;
    } catch (_) {
      if (!isDisposed) {
        inventoryStatus =
            'Model inventory check failed. Check the local server and retry.';
      }
    } finally {
      busy = false;
      update();
    }
  }

  static Duration Function() _monotonicClock() {
    final clock = Stopwatch()..start();
    return () => clock.elapsed;
  }

  final DateTime Function() _now;
  final Duration Function() _elapsed;
  ModelTestObservation? _pendingObservation;
  LocalModelConfig? _testedConfig;

  static bool _sameConnection(LocalModelConfig a, LocalModelConfig b) =>
      a.baseUrl == b.baseUrl &&
      a.model == b.model &&
      a.chatOutputTokens == b.chatOutputTokens;

  bool canSaveProfileNotes(LocalModelConfig draft) =>
      !busy &&
      !isDisposed &&
      !settingsLoadFailed &&
      !presetsLoadFailed &&
      _presets.any(
        (p) => p.name == selectedPreset && _sameConnection(p.config, draft),
      );

  Future<void> saveProfileNotes(
    LocalModelConfig draft,
    ModelProfileNotes? notes,
  ) async {
    if (!canSaveProfileNotes(draft)) return;
    await _writePresets(
      [
        for (final p in _presets)
          if (p.name == selectedPreset)
            ModelConnectionPreset(
              name: p.name,
              config: p.config,
              profileNotes: notes?.isEmpty == true ? null : notes,
              testObservation: p.testObservation,
            )
          else
            p,
      ],
      'Profile notes saved to selected preset. Connection, historical test and active settings are unchanged.',
    );
  }

  bool canSaveTestObservation(LocalModelConfig draft) =>
      !busy &&
      !isDisposed &&
      !settingsLoadFailed &&
      !presetsLoadFailed &&
      _pendingObservation != null &&
      _testedConfig != null &&
      _sameConnection(draft, _testedConfig!) &&
      _presets.any(
        (p) => p.name == selectedPreset && _sameConnection(p.config, draft),
      );

  Future<void> saveTestObservation(LocalModelConfig draft) async {
    if (!canSaveTestObservation(draft)) return;
    final observation = _pendingObservation!;
    await _writePresets(
      [
        for (final p in _presets)
          if (p.name == selectedPreset)
            ModelConnectionPreset(
              name: p.name,
              config: p.config,
              profileNotes: p.profileNotes,
              testObservation: observation,
            )
          else
            p,
      ],
      'Historical test observation saved to selected preset. Active settings are unchanged.',
    );
  }

  bool get canRemoveTestObservation =>
      !busy &&
      !isDisposed &&
      !settingsLoadFailed &&
      !presetsLoadFailed &&
      _presets.any(
        (p) => p.name == selectedPreset && p.testObservation != null,
      );

  Future<void> removeTestObservation() async {
    if (!canRemoveTestObservation) return;
    await _writePresets(
      [
        for (final p in _presets)
          if (p.name == selectedPreset)
            ModelConnectionPreset(
              name: p.name,
              config: p.config,
              profileNotes: p.profileNotes,
            )
          else
            p,
      ],
      'Saved historical test removed from selected preset. Connection, profile notes and active settings are unchanged.',
      clearPendingObservation: true,
    );
  }

  static const timingGuidance =
      'Successful tests show temporary client-observed latency from dispatch to '
      'first nonblank text and completed response, including connection and '
      'transport overhead. These are not model token speed or capacity measurements.';

  final ModelSettingsStore store;
  final ProviderFactory _createProvider;
  ModelProvider? _provider;
  StreamSubscription<String>? _subscription;
  Timer? _deadline;
  Completer<void>? _completion;
  int _request = 0;
  bool get testing => _completion != null;
  static const probeTimeout = Duration(seconds: 30);
  static const probeOutputLimit = 4096;
  static const requestLimits =
      'Connection test: 30 seconds total, 4096 text characters, 256 output tokens. '
      'Transport startup: 15 seconds; inactivity: 30 seconds. '
      'Stop closes this app connection; server-side inference may continue.';
  bool settingsLoadFailed = false;
  LocalModelConfig get initial {
    try {
      return store.load();
    } catch (_) {
      settingsLoadFailed = true;
      status = 'Saved model settings could not be loaded. Records have not been overwritten. Restore valid settings before saving or testing.';
      return const LocalModelConfig();
    }
  }

  List<ModelConnectionPreset> _presets = const [];
  List<ModelConnectionPreset> get presets => List.unmodifiable(_presets);
  bool presetsLoadFailed = false;
  String? selectedPreset;
  String presetStatus =
      'Presets restore a draft only. Save applies the connection to later requests; Test checks the server separately. No model is loaded or verified by a preset.';

  LocalModelConfig? selectPreset(String name) {
    if (busy || presetsLoadFailed || settingsLoadFailed || isDisposed) {
      return null;
    }
    for (final preset in _presets) {
      if (preset.name == name) {
        connectionDraftChanged();
        selectedPreset = name;
        presetStatus = 'Preset restored into the draft. Choose Save to apply it or Test model to check the connection.';
        update();
        return preset.config;
      }
    }
    return null;
  }

  Future<void> savePreset(
    String name,
    LocalModelConfig config, {
    bool replace = false,
    ModelProfileNotes? profileNotes,
  }) async {
    if (busy || presetsLoadFailed || settingsLoadFailed || isDisposed) return;
    final preset = ModelConnectionPreset(
      name: name.trim(),
      config: config,
      profileNotes: profileNotes,
    );
    final exists = _presets.any((p) => p.name == preset.name);
    if ((replace && (!exists || selectedPreset != preset.name)) ||
        (!replace && exists)) {
      presetStatus = 'That name already exists or is not selected. Select it and use Replace selected, or choose a new name.';
      update();
      return;
    }
    await _writePresets([
      for (final p in _presets)
        if (p.name != preset.name) p,
      preset,
    ], 'Connection preset saved. Active settings are unchanged.');
  }

  Future<void> removePreset() async {
    if (busy ||
        presetsLoadFailed ||
        settingsLoadFailed ||
        isDisposed ||
        selectedPreset == null) {
      return;
    }
    await _writePresets([
      for (final p in _presets)
        if (p.name != selectedPreset) p,
    ], 'Selected preset removed. Draft and active settings are unchanged.');
  }

  Future<void> _writePresets(
    List<ModelConnectionPreset> next,
    String message, {
    bool clearPendingObservation = false,
  }) async {
    busy = true;
    update();
    try {
      await store.savePresets(next, expected: _presets);
      if (isDisposed) return;
      _presets = List.unmodifiable(next);
      if (clearPendingObservation) {
        _pendingObservation = null;
        _testedConfig = null;
      }
      if (!_presets.any((p) => p.name == selectedPreset)) selectedPreset = null;
      presetStatus = message;
    } on FormatException {
      if (!isDisposed) presetStatus = 'Invalid preset. Use a unique name (1–64 characters), local URL (up to 512), model ID (up to 256) and supported token limit; at most 20 presets. Profile notes must be trimmed text of up to 256 characters each, with a declared context limit of 1–1048576 tokens.';
    } catch (_) {
      if (!isDisposed) presetStatus = 'Presets could not be saved. Previous presets and draft are retained; check storage, close and reopen settings, then retry.';
    } finally {
      busy = false;
      if (!isDisposed) update();
    }
  }

  String status =
      'Qwen 9B selected as the initial model family. Confirm the exact server model ID before testing.';
  bool busy = false;
  Future<void> save(LocalModelConfig config) async {
    if (busy || settingsLoadFailed || isDisposed) return;
    busy = true;
    update();
    try {
      await store.save(config);
      status = 'Settings saved. Model availability has not been verified.';
    } on FormatException {
      status = 'Invalid connection settings. Use a local HTTP URL without credentials, query or fragment, a nonempty model ID and a supported chat token limit.';
    } catch (_) {
      status = 'Settings could not be saved. Check local storage and retry.';
    } finally {
      busy = false;
      update();
    }
  }

  Future<void> test(LocalModelConfig config, {bool jsonFormat = false}) async {
    if (busy || settingsLoadFailed || isDisposed) return;
    busy = true;
    runtimeMetrics = null;
    _pendingObservation = null;
    _testedConfig = null;
    final request = ++_request;
    final completion = Completer<void>();
    _completion = completion;
    status = 'Connection test active. Waiting for a completed model response…';
    update();
    final started = _elapsed();
    Duration? firstText;
    var characters = 0;
    var hasText = false;
    final response = StringBuffer();
    try {
      // Validate before creating a provider, including injected providers.
      config.endpoint;
      config.validateChatLimit();
      _provider = _createProvider(config);
      _deadline = Timer(probeTimeout, () {
        if (request == _request) {
          _finish('Connection test timed out. Check the runtime and retry.');
        }
      });
      _subscription = _provider!
          .generate(
            jsonFormat ? ModelFormatProbe.prompt : 'Reply with one short sentence confirming you can help plan a software project.',
          )
          .listen(
            (text) {
              if (request != _request || isDisposed) return;
              characters += text.length;
              if (text.trim().isNotEmpty) {
                firstText ??= _elapsed() - started;
                hasText = true;
              }
              if (characters > probeOutputLimit) {
                _finish(
                  'Connection test stopped: response exceeded the text limit.',
                );
              } else if (jsonFormat) {
                response.write(text);
              }
            },
            onError: (Object error) {
              if (request != _request || isDisposed) return;
              _finish(
                error is TimeoutException
                    ? 'Connection test timed out. Check the runtime and retry.'
                    : 'Connection test failed. Check the local server, model ID and streaming API, then retry.',
              );
            },
            onDone: () {
              if (request != _request || isDisposed) return;
              final successful = jsonFormat
                  ? ModelFormatProbe.accepts(response.toString())
                  : hasText;
              final firstTextLatency = firstText;
              final completed = _elapsed() - started;
              if (successful && firstTextLatency != null) {
                final provider = _provider;
                final metrics = provider is ModelMetricsProvider
                    ? provider.completedMetrics
                    : null;
                final observation = ModelTestObservation(
                  jsonFormat: jsonFormat,
                  observedAt: _now().toUtc(),
                  firstTextMilliseconds: firstTextLatency.inMilliseconds,
                  completedMilliseconds: completed.inMilliseconds,
                  runtimeMetrics: metrics,
                );
                // A late completion must never create an out-of-budget record.
                if (firstTextLatency >= Duration.zero &&
                    completed >= firstTextLatency &&
                    completed <= probeTimeout) {
                  _pendingObservation = observation;
                  _testedConfig = config;
                  runtimeMetrics = metrics;
                }
              }
              final timing = successful && firstTextLatency != null
                  ? ' Client-observed first text: ${firstTextLatency.inMilliseconds} ms; completed response: ${completed.inMilliseconds} ms. Requested model ID: ${config.model}. This observation is not saved automatically.'
                  : '';
              _finish(
                (jsonFormat
                        ? successful
                              ? 'Draft connection returned the expected JSON object in one completed response. Requested model ID: ${config.model}. Loaded identity and general schema/tool compatibility remain unverified. Settings are unchanged; this observation is not saved.'
                              : 'JSON format test failed: response did not match the expected JSON object. Response text is omitted. Check the model and retry; settings are unchanged.'
                        : hasText
                        ? 'Local server completed the connection test. Response text is omitted.'
                        : 'Connection test failed: the server returned no text. Check the model ID and runtime.') +
                    timing,
              );
            },
          );
    } on FormatException {
      _finish(
        'Invalid connection settings. Use a local HTTP URL without credentials, query or fragment, a nonempty model ID and a supported chat token limit.',
      );
    } catch (_) {
      _finish(
        'Connection test failed. Check the local server and model ID, then retry.',
      );
    }
    await completion.future;
  }

  void stopTest() {
    if (!testing || isDisposed) return;
    runtimeMetrics = null;
    _finish(
      'Connection test stopped. App connection closed; server-side inference may continue.',
    );
  }

  void _finish(String message) {
    ++_request;
    _deadline?.cancel();
    _deadline = null;
    final subscription = _subscription;
    final provider = _provider;
    _subscription = null;
    _provider = null;
    // Cleanup must not keep the UI busy if an external provider stalls or fails.
    if (subscription != null) unawaited(_ignoreCleanup(subscription.cancel));
    if (provider != null) unawaited(_ignoreCleanup(provider.cancel));
    final completion = _completion;
    _completion = null;
    if (completion != null && !completion.isCompleted) completion.complete();
    busy = false;
    status = message;
    update();
  }

  Future<void> _ignoreCleanup(Future<void> Function() cleanup) async {
    try {
      await cleanup();
    } catch (_) {
      // Never render transport errors: they can contain private response text.
    }
  }

  @override
  void dispose() {
    runtimeMetrics = null;
    _finish('Connection test closed.');
    super.dispose();
  }
}
