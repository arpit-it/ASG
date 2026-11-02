// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../project_runner.dart';
import 'html_source_check.dart';

enum RunnerResultStatus { completed, unsupported }

class HtmlRunnerResult {
  const HtmlRunnerResult({
    required this.operation,
    required this.status,
    required this.detail,
    this.sourceCheck,
    this.previewUrl,
  });
  final RunnerOperation operation;
  final RunnerResultStatus status;
  final String detail;
  final HtmlSourceCheck? sourceCheck;
  final Uri? previewUrl;
}
