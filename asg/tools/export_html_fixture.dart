// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:io';

import 'package:asg/models/html/html_site_input.dart';
import 'package:asg/services/html/html_site_template.dart';

/// Disposable acceptance fixture only, never the production export path.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 1 || await Directory(arguments.single).exists()) {
    throw ArgumentError('Choose one new disposable fixture directory.');
  }
  final files = HtmlSiteTemplate().generate(
    HtmlSiteInput(
      title: 'Community garden <local> & friends',
      description: 'Grow together.\nEditable, independent web source.',
    ),
  );
  final target = Directory(arguments.single);
  await target.create(recursive: true);
  for (final entry in files.entries) {
    final file = File('${target.path}/${entry.key}');
    await file.parent.create(recursive: true);
    await file.writeAsString(entry.value, flush: true);
  }
}
