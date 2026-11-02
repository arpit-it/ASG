// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../../models/html/html_export_request.dart';
import 'html_source_export.dart';

class HtmlSourceExportStub implements HtmlSourceExport {
  @override
  bool get supported => false;
  @override
  Future<String> export({
    required HtmlExportRequest request,
    required HtmlExportRequest? confirmedRequest,
    required void Function() authorizeWrite,
  }) async => throw UnsupportedError('HTML source export requires macOS.');
}

HtmlSourceExport createHtmlSourceExport() => HtmlSourceExportStub();
