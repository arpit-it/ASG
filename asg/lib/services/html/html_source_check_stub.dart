// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../../models/html/html_site_input.dart';
import '../../models/html/html_source_check.dart';
import 'html_source_check.dart';

class UnsupportedHtmlSourceChecker implements HtmlSourceChecker {
  @override
  bool get supported => false;
  @override
  Future<HtmlSourceCheck> check({
    required String directory,
    required HtmlSiteInput input,
    required void Function() authorizeRead,
  }) async =>
      throw UnsupportedError('Fixed HTML source verification requires macOS.');
}

HtmlSourceChecker createHtmlSourceChecker() => UnsupportedHtmlSourceChecker();
