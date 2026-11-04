// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:io';

import '../../models/html/html_source_proposal.dart';
import 'html_reviewed_preview.dart';
import 'html_preview_host_native.dart';
import 'html_preview_native.dart';

class NativeHtmlReviewedPreview implements HtmlReviewedPreview {
  final _host = HtmlPreviewHostNative();
  late final _launcher = HtmlPreviewNative(host: _host);
  @override
  bool get supported => Platform.isMacOS;
  @override
  Future<Uri> start({
    required String directory,
    required HtmlSourceProposal proposal,
    required void Function() authorizeRead,
  }) => _host.startReviewed(
    directory: directory,
    proposal: proposal,
    authorizeRead: authorizeRead,
  );
  @override
  Future<void> open() => _launcher.open();
  @override
  Future<void> stop() => _host.stop();
}

HtmlReviewedPreview createHtmlReviewedPreview() => NativeHtmlReviewedPreview();
