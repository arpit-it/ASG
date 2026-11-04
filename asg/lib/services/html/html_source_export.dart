// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../../models/html/html_export_request.dart';

abstract class HtmlSourceExport {
  bool get supported;
  Future<String> export({
    required HtmlExportRequest request,
    required HtmlExportRequest? confirmedRequest,
    required void Function() authorizeWrite,
  });
}

/// Writes reviewed, untrusted sources only into an exclusively new folder.
/// The caller must display the complete proposal and destination, explicitly
/// confirm them and retain current review authority at each write boundary.
abstract class HtmlReviewedSourceExport {
  bool get supported;
  Future<String> exportReviewed({
    required HtmlReviewedExportRequest request,
    required HtmlReviewedExportRequest? confirmedRequest,
    required void Function() authorizeWrite,
  });
}
