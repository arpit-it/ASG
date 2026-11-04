// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../../models/html/html_source_proposal.dart';
import 'html_reviewed_preview_stub.dart'
    if (dart.library.io) 'html_reviewed_preview_native.dart'
    as platform;

/// Passive preview only. A caller must explicitly confirm the exact proposal
/// and own Stop, deadline, source authority and disposal.
abstract class HtmlReviewedPreview {
  bool get supported;
  Future<Uri> start({
    required String directory,
    required HtmlSourceProposal proposal,
    required void Function() authorizeRead,
  });
  Future<void> open();
  Future<void> stop();
}

HtmlReviewedPreview createHtmlReviewedPreview() =>
    platform.createHtmlReviewedPreview();
