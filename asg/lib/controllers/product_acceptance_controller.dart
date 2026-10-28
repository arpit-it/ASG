// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/foundation.dart';

import '../models/product_acceptance_report.dart';

class ProductAcceptanceController extends ChangeNotifier {
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
