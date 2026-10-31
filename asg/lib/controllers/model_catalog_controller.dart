// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import '../models/model_catalog.dart';
import '../services/model_catalog_service.dart';
import '../services/model_hardware.dart';
import 'base_controller.dart';

class ModelCatalogController extends BaseController {
  ModelCatalogController({
    ModelCatalogService? service,
    Future<ModelHardware> Function()? probe,
  }) : service = service ?? ModelCatalogService(),
       _probe = probe ?? probeModelHardware;
  final ModelCatalogService service;
  final Future<ModelHardware> Function() _probe;
  ModelHardware _hardware = const ModelHardware(
    appleSilicon: false,
    detail: 'Detecting host memory…',
  );
  ModelHardware get hardware => _hardware;
  final _metadata = <String, ModelCatalogMetadata>{};
  final _errors = <String, String>{};
  String? _checking;
  final _entries = [...codingModelCatalog];
  bool _discovering = false;
  String? _searchError;
  String? get searchError => _searchError;
  bool _initializing = false;
  bool get busy =>
      _refreshing || _initializing || _checking != null || _discovering;
  String? get checking => _checking;
  String _query = '';
  bool _preferredOnly = true;
  bool get preferredOnly => _preferredOnly;
  bool _refreshing = false;
  bool get refreshing => _refreshing;

  // Deliberate quality tiers for the currently enabled architecture, not a
  // parameter-count ranking of arbitrary public search results.
  static const preferredRepositories = [
    'mlx-community/Qwen3.5-27B-4bit',
    'mlx-community/Qwen3.5-9B-4bit',
  ];
  List<ModelCatalogEntry> get preferredEntries {
    for (final repository in preferredRepositories) {
      final entry = _entries.firstWhere((e) => e.repository == repository);
      if (assessment(entry).fit == ModelFit.estimatedFit) return [entry];
    }
    return const [];
  }

  void showPreferredOnly(bool value) {
    _preferredOnly = value;
    update();
  }

  Future<void> refreshPreferred() async {
    if (isDisposed || busy) return;
    _refreshing = true;
    update();
    try {
      for (final repository in preferredRepositories) {
        if (isDisposed) return;
        final entry = _entries.firstWhere((e) => e.repository == repository);
        await _checkEntry(entry);
      }
    } finally {
      _refreshing = false;
      update();
    }
  }

  bool _compatibleOnly = true;
  bool get compatibleOnly => _compatibleOnly;
  List<ModelCatalogEntry> get entries => List.unmodifiable(
    (_preferredOnly ? preferredEntries : _entries).where((entry) {
      final model = _metadata[entry.repository];
      return (!_compatibleOnly || model == null || model.runtimeCompatible) &&
          '${entry.name} ${entry.repository} ${entry.description}'
              .toLowerCase()
              .contains(_query);
    }),
  );
  ModelCatalogMetadata? metadata(ModelCatalogEntry entry) =>
      _metadata[entry.repository];
  String? error(ModelCatalogEntry entry) => _errors[entry.repository];
  ModelAssessment assessment(ModelCatalogEntry entry) =>
      ModelAssessment.assess(_hardware, metadata(entry));
  void search(String query) {
    _query = query.trim().toLowerCase();
    update();
  }

  void showCompatibleOnly(bool value) {
    _compatibleOnly = value;
    update();
  }

  Future<void> initialize() async {
    if (isDisposed || _initializing) return;
    _initializing = true;
    update();
    try {
      final value = await _probe();
      if (!isDisposed) _hardware = value;
    } catch (_) {
      if (!isDisposed) {
        _hardware = const ModelHardware(
          appleSilicon: false,
          detail: 'Hardware detection failed. Retry by reopening the catalog.',
        );
      }
    } finally {
      _initializing = false;
      update();
    }
  }

  Future<void> check(ModelCatalogEntry entry) async {
    if (isDisposed || busy) return;
    await _checkEntry(entry);
  }

  Future<void> _checkEntry(ModelCatalogEntry entry) async {
    _checking = entry.repository;
    _metadata.remove(entry.repository);
    _errors.remove(entry.repository);
    update();
    try {
      final result = await service.check(entry);
      if (!isDisposed) _metadata[entry.repository] = result;
    } catch (_) {
      if (!isDisposed) _errors[entry.repository] = 'Source check failed or artifacts are incomplete. Retry when online. No settings or files were changed.';
    } finally {
      _checking = null;
      update();
    }
  }

  Future<void> discover() async {
    if (isDisposed || busy) return;
    _discovering = true;
    _searchError = null;
    update();
    try {
      final found = await service.search(_query.isEmpty ? 'coder' : _query);
      if (isDisposed) return;
      for (final entry in found) {
        if (!_entries.any((e) => e.repository == entry.repository)) {
          _entries.add(entry);
        }
      }
      if (found.isEmpty) {
        _searchError =
            'No matching MLX 4-bit candidates found. Try another model family.';
      }
    } catch (_) {
      if (!isDisposed) {
        _searchError =
            'Public search failed. Retry with a model name when online.';
      }
    } finally {
      _discovering = false;
      update();
    }
  }

  ModelCatalogChoice? choose(ModelCatalogEntry entry) {
    if (isDisposed || busy || !assessment(entry).canChoose) return null;
    final value = metadata(entry);
    return value == null ? null : ModelCatalogChoice(entry, value);
  }

  @override
  void dispose() {
    service.close();
    super.dispose();
  }
}
