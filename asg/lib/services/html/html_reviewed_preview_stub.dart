// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../../models/html/html_source_proposal.dart';
import 'html_reviewed_preview.dart';

class UnsupportedHtmlReviewedPreview implements HtmlReviewedPreview {
  @override
  bool get supported => false;
  @override
  Future<Uri> start({
    required String directory,
    required HtmlSourceProposal proposal,
    required void Function() authorizeRead,
  }) async => throw UnsupportedError('Reviewed HTML preview requires macOS.');
  @override
  Future<void> open() async =>
      throw UnsupportedError('Browser launch requires macOS.');
  @override
  Future<void> stop() async {}
}

HtmlReviewedPreview createHtmlReviewedPreview() =>
    UnsupportedHtmlReviewedPreview();
