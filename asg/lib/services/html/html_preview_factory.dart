// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'html_preview.dart';
import 'html_preview_stub.dart'
    if (dart.library.io) 'html_preview_native.dart'
    as host;

HtmlPreview createHtmlPreview() => host.createHtmlPreview();
