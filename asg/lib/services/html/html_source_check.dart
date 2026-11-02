// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../../models/html/html_site_input.dart';
import '../../models/html/html_source_check.dart';
export 'html_source_check_stub.dart'
    if (dart.library.io) 'html_source_check_native.dart'
    show createHtmlSourceChecker;

abstract class HtmlSourceChecker {
  bool get supported;
  Future<HtmlSourceCheck> check({
    required String directory,
    required HtmlSiteInput input,
    required void Function() authorizeRead,
  });
}
