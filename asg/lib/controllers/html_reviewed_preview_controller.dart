// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';

import '../models/html/html_source_proposal.dart';
import '../services/html/html_reviewed_preview.dart';
import 'base_controller.dart';

class HtmlReviewedPreviewController extends BaseController {
  HtmlReviewedPreviewController({
    required this.proposal,
    required this.directory,
    required this.authorizeSource,
    HtmlReviewedPreview? preview,
    this.deadline = const Duration(seconds: 10),
  }) : assert(deadline > Duration.zero),
       preview = preview ?? createHtmlReviewedPreview();
  final HtmlSourceProposal proposal;
  final String directory;
  final void Function() authorizeSource;
  final HtmlReviewedPreview preview;
  final Duration deadline;
  bool busy = false, stopping = false, opening = false;
  Uri? url;
  String? error;
  int _generation = 0;

  bool get supported => preview.supported;
  bool get locked => busy || stopping || opening || url != null;

  Future<void> confirm() async {
    if (isDisposed || locked || !supported) return;
    final generation = ++_generation;
    busy = true;
    error = null;
    update();
    void authorize() {
      if (isDisposed || generation != _generation) {
        throw StateError('Passive preview revoked.');
      }
      authorizeSource();
    }

    final timer = Timer(deadline, () {
      if (isDisposed || generation != _generation || !busy) return;
      unawaited(stop());
      error = 'Preview deadline reached. Waiting for startup to return; no result will be published.';
      update();
    });
    try {
      authorize();
      final result = await preview.start(
        directory: directory,
        proposal: proposal,
        authorizeRead: authorize,
      );
      authorize();
      url = result;
    } catch (_) {
      _generation++;
      url = null;
      if (!isDisposed) error ??= 'Preview failed, stopped or source review changed. Nothing was applied. Retry after startup returns.';
      try {
        await preview.stop();
      } catch (_) {
        if (!isDisposed) error = 'Preview cleanup failed. Source authority is revoked; leave this screen closed.';
      }
    } finally {
      timer.cancel();
      busy = false;
      error = error?.replaceFirst(
        'Waiting for startup to return;',
        'Startup has returned;',
      );
      update();
    }
  }

  Future<void> open() async {
    if (isDisposed || busy || stopping || opening || url == null) return;
    opening = true;
    error = null;
    update();
    try {
      authorizeSource();
      await preview.open();
    } catch (_) {
      if (!isDisposed) error = 'Browser launch failed or source review changed. Stop the preview and retry. An already-launched browser cannot be recalled.';
      await stop();
    } finally {
      opening = false;
      update();
    }
  }

  Future<void> stop() async {
    if (isDisposed || stopping) return;
    _generation++;
    url = null;
    stopping = true;
    if (busy) error = 'Preview stopped. Waiting for startup to return; no result will be published.';
    update();
    try {
      await preview.stop();
    } catch (_) {
      if (!isDisposed) error = 'Preview cleanup failed. Leave this screen closed; the revoked source authority refuses further responses.';
    } finally {
      stopping = false;
      update();
    }
  }

  @override
  void dispose() {
    _generation++;
    url = null;
    unawaited(preview.stop().catchError((Object _) {}));
    super.dispose();
  }
}
