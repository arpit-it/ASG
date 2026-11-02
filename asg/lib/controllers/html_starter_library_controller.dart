// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/html/saved_html_starter.dart';
import '../services/html/html_starter_store.dart';
import 'base_controller.dart';

class HtmlStarterLibraryController extends BaseController {
  HtmlStarterLibraryController(this.store) {
    reload();
  }
  final HtmlStarterStore store;
  List<SavedHtmlStarter> _starters = const [];
  List<SavedHtmlStarter> get starters => _starters;
  String? error;
  void reload() {
    if (isDisposed) return;
    try {
      _starters = store.load();
      error = null;
    } catch (_) {
      _starters = const [];
      error = 'Saved HTML starters could not be read. Existing data is retained; restore local storage before retrying.';
    }
    update();
  }
}
