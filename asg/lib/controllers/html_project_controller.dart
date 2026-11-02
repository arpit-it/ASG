// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/project.dart';
import '../models/html/saved_html_starter.dart';
import '../services/html/html_project_store.dart';
import 'base_controller.dart';

class HtmlProjectController extends BaseController {
  HtmlProjectController(this.store, this.project) {
    reload();
  }
  final HtmlProjectStore store;
  final StudioProject project;
  SavedHtmlStarter? starter;
  String? error;
  void reload() {
    if (isDisposed) return;
    try {
      starter = store.resolve(project);
      error = null;
    } catch (_) {
      starter = null;
      error = 'Original HTML starter metadata is missing or changed. No Flutter fallback will run. Restore local project and starter records, then retry.';
    }
    update();
  }
}
