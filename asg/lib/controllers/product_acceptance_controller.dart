// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/foundation.dart';

import '../models/product_acceptance_report.dart';
import '../models/product_acceptance_manifest.dart';
import '../services/product_acceptance_manifest_service.dart';

class ProductAcceptanceController extends ChangeNotifier {
  ProductAcceptanceController({
    Future<ProductAcceptanceManifest> Function()? manifestLoader,
  }) : _manifestLoader =
           manifestLoader ?? ProductAcceptanceManifestService().load;
  final Future<ProductAcceptanceManifest> Function() _manifestLoader;
  ProductAcceptanceManifest? _manifest;
  bool _manifestLoading = false;
  bool get manifestLoading => _manifestLoading;
  String? _manifestError;
  String? get manifestError => _manifestError;
  String? get bundledManifestSha256 => _manifest?.sha256Digest;
  ProductAcceptanceComparison? get comparison =>
      _manifest == null || _report == null
      ? null
      : _manifest!.compare(_report!);

  Future<void> loadManifest() async {
    if (_disposed || _manifestLoading) return;
    _manifestLoading = true;
    _manifestError = null;
    notifyListeners();
    try {
      final manifest = await _manifestLoader();
      if (!_disposed) _manifest = manifest;
    } catch (_) {
      if (!_disposed) {
        _manifest = null;
        _manifestError = 'Bundled manifest comparison unavailable. Retry loading the specification.';
      }
    } finally {
      if (!_disposed) {
        _manifestLoading = false;
        notifyListeners();
      }
    }
  }

  ProductAcceptanceReport? _report;
  ProductAcceptanceReport? get report => _report;
  String? _error;
  String? get error => _error;
  bool _disposed = false;

  void inspect(String source) {
    if (_disposed) return;
    try {
      _report = ProductAcceptanceReport.parse(source);
      _error = null;
    } catch (_) {
      _error = 'Invalid saved report. Use an unmodified collector report of at most 1 MiB. The previous report is retained.';
    }
    notifyListeners();
  }

  void clear() {
    if (_disposed) return;
    _report = null;
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
