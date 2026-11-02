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
