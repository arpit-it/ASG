// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'html_source_export.dart';
import 'html_source_export_stub.dart'
    if (dart.library.io) 'html_source_export_native.dart'
    as host;

HtmlSourceExport createHtmlSourceExport() => host.createHtmlSourceExport();

HtmlReviewedSourceExport createHtmlReviewedSourceExport() =>
    host.createHtmlReviewedSourceExport();
