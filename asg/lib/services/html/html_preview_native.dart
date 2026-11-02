// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:io';

import '../../models/html/html_site_input.dart';
import 'html_preview.dart';
import 'html_preview_host_native.dart';

class HtmlPreviewNative implements HtmlPreview {
  final _host = HtmlPreviewHostNative();
  @override
  bool get supported => Platform.isMacOS;
  @override
  Future<Uri> start({
    required String directory,
    required HtmlSiteInput input,
  }) => _host.start(directory: directory, input: input);

  @override
  Future<void> open() async {
    final url = _host.url;
    if (!supported || url == null) throw StateError('Start a preview first.');
    // Only the service-owned tokenized loopback URL can reach the OS launcher.
    final launch = Process.start('/usr/bin/open', [url.toString()]);
    late Process process;
    try {
      process = await launch.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      // A timed-out spawn may still complete. Retain cleanup ownership.
      unawaited(
        launch
            .then<void>((lateProcess) {
              unawaited(lateProcess.stdout.drain<void>());
              unawaited(lateProcess.stderr.drain<void>());
              lateProcess.kill();
            })
            .catchError((Object _) {}),
      );
      rethrow;
    }
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    try {
      if (await process.exitCode.timeout(const Duration(seconds: 5)) != 0) {
        throw StateError('The browser launch request failed.');
      }
    } on TimeoutException {
      process.kill();
      rethrow;
    }
  }

  @override
  Future<void> stop() => _host.stop();
}

HtmlPreview createHtmlPreview() => HtmlPreviewNative();
