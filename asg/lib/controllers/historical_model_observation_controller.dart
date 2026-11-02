// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import '../models/historical_model_observation.dart';
import '../services/historical_model_observation_store.dart';
import 'base_controller.dart';

class HistoricalModelObservationController extends BaseController {
  HistoricalModelObservationController({HistoricalModelObservationStore? store})
    : _store = store ?? HistoricalModelObservationStore();
  final HistoricalModelObservationStore _store;
  HistoricalModelObservation? _observation;
  HistoricalModelObservation? get observation => _observation;
  bool _loading = false;
  bool get loading => _loading;
  String? _error;
  String? get error => _error;

  Future<void> load() async {
    if (isDisposed || loading || observation != null) return;
    _loading = true;
    _error = null;
    update();
    try {
      final result = await _store.load();
      if (!isDisposed) _observation = result;
    } catch (_) {
      if (!isDisposed) _error = 'Historical observation unavailable. Retry loading the bundled report.';
    } finally {
      _loading = false;
      update();
    }
  }
}
