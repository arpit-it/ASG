// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../../models/html/html_site_input.dart';

/// One screen owns one preview and must stop it when leaving.
abstract class HtmlPreview {
  bool get supported;

  /// Optional caller authority is checked at each native read/bind boundary and
  /// before serving each request. Stop and cleanup remain caller-owned.
  Future<Uri> start({
    required String directory,
    required HtmlSiteInput input,
    void Function()? authorizeRead,
  });
  Future<void> open();
  Future<void> stop();
}
