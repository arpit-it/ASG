// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/project_runner.dart';
import 'html/html_starter_runner.dart';

/// Only registered runners are discoverable; language names do not grant support.
/// The legacy Flutter workflow is separate until explicitly registered.
class ProjectRunnerRegistry {
  ProjectRunnerRegistry({HtmlStarterRunner? html})
    : _html = html ?? HtmlStarterRunner();
  final HtmlStarterRunner _html;

  ProjectRunnerDescriptor? discover(String outputStack) =>
      outputStack == 'HTML' ? _html.descriptor : null;

  HtmlStarterRunner? htmlRunner(String outputStack) =>
      outputStack == 'HTML' ? _html : null;
}
