// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../../models/html/html_source_proposal.dart';
import 'html_reviewed_source_check.dart';

class UnsupportedHtmlReviewedSourceChecker
    implements HtmlReviewedSourceChecker {
  @override
  bool get supported => false;
  @override
  Future<HtmlReviewedSourceCheck> check({
    required String directory,
    required HtmlSourceProposal proposal,
    required void Function() authorizeRead,
  }) async =>
      throw UnsupportedError('Reviewed source identity requires macOS.');
}

HtmlReviewedSourceChecker createHtmlReviewedSourceChecker() =>
    UnsupportedHtmlReviewedSourceChecker();
