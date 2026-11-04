// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../../models/html/html_source_proposal.dart';
export 'html_reviewed_source_check_stub.dart'
    if (dart.library.io) 'html_reviewed_source_check_native.dart'
    show createHtmlReviewedSourceChecker;

/// Point-in-time byte identity only; never syntax, safety or browser approval.
class HtmlReviewedSourceCheck {
  const HtmlReviewedSourceCheck({required this.files, required this.bytes});
  final int files, bytes;
  String get summary =>
      '$files reviewed source files match ($bytes bytes). '
      'Point-in-time identity only; source remains untrusted. '
      'No syntax, safety, browser or runtime checks.';
}

abstract class HtmlReviewedSourceChecker {
  bool get supported;
  Future<HtmlReviewedSourceCheck> check({
    required String directory,
    required HtmlSourceProposal proposal,
    required void Function() authorizeRead,
  });
}
