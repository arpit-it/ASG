// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../../models/html/html_site_input.dart';
import 'html_preview.dart';

class HtmlPreviewStub implements HtmlPreview {
  @override
  bool get supported => false;
  @override
  Future<Uri> start({
    required String directory,
    required HtmlSiteInput input,
  }) async => throw UnsupportedError('Fixed HTML preview requires macOS.');
  @override
  Future<void> open() async =>
      throw UnsupportedError('Browser launch requires macOS.');
  @override
  Future<void> stop() async {}
}

HtmlPreview createHtmlPreview() => HtmlPreviewStub();
