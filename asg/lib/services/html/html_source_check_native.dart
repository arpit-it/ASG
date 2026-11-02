// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:io';

import '../../models/html/html_site_input.dart';
import '../../models/html/html_source_check.dart';
import 'html_source_check.dart';
import 'html_starter_snapshot_native.dart';

class NativeHtmlSourceChecker implements HtmlSourceChecker {
  @override
  bool get supported => Platform.isMacOS;
  @override
  Future<HtmlSourceCheck> check({
    required String directory,
    required HtmlSiteInput input,
    required void Function() authorizeRead,
  }) async {
    final snapshot = await readHtmlStarterSnapshot(
      directory: directory,
      input: input,
      check: authorizeRead,
    );
    return HtmlSourceCheck(
      files: snapshot.length,
      bytes: snapshot.values.fold(0, (total, bytes) => total + bytes.length),
    );
  }
}

HtmlSourceChecker createHtmlSourceChecker() => NativeHtmlSourceChecker();
