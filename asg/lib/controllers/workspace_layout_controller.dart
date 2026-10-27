// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/foundation.dart';

/// Session-only pane preferences; never modifies project or generation state.
class WorkspaceLayoutController extends ChangeNotifier {
  double _fraction = 0.4;
  int? _collapsed;
  int _mobilePane = 0;

  double get fraction => _fraction;
  int? get collapsed => _collapsed;
  int get mobilePane => _mobilePane;

  void resize(double fraction, double minimumFraction) {
    if (!fraction.isFinite || !minimumFraction.isFinite) return;
    final minimum = minimumFraction.clamp(0.0, 0.5);
    _fraction = fraction.clamp(minimum, 1 - minimum);
    notifyListeners();
  }

  void toggle(int pane) {
    if (pane != 0 && pane != 1) return;
    _collapsed = _collapsed == pane ? null : pane;
    notifyListeners();
  }

  void select(int pane) {
    if (pane != 0 && pane != 1) return;
    _mobilePane = pane;
    notifyListeners();
  }
}
