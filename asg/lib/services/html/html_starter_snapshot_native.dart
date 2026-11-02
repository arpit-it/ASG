// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../../models/html/html_site_input.dart';
import 'html_site_template.dart';

/// Bounded read-only identity check, shared with preview. No syntax/runtime
/// checks, directory traversal or execution. A cooperative filesystem is assumed.
Future<Map<String, List<int>>> readHtmlStarterSnapshot({
  required String directory,
  required HtmlSiteInput input,
  required void Function() check,
}) async {
  if (!Platform.isMacOS) {
    throw UnsupportedError('Fixed HTML source verification requires macOS.');
  }
  check();
  if (!path.isAbsolute(directory) ||
      await Directory(directory).resolveSymbolicLinks() !=
          path.normalize(directory)) {
    throw const FormatException('Choose a real absolute export directory.');
  }
  final sources = HtmlSiteTemplate().generate(input);
  final snapshot = <String, List<int>>{};
  for (final entry in sources.entries) {
    check();
    final file = File(path.join(directory, entry.key));
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.resolveSymbolicLinks() != file.path) {
      throw const FormatException('Export file is missing or symbolic.');
    }
    final expected = utf8.encode(entry.value);
    // Bound reads even if the file grows after inspection; do not load an
    // arbitrary file into memory. Exact bytes bind preview to this input.
    check();
    final reader = await file.open();
    late List<int> bytes;
    try {
      check();
      bytes = await reader.read(expected.length + 1);
    } finally {
      await reader.close();
    }
    if (bytes.length != expected.length ||
        !Iterable<int>.generate(bytes.length)
            .every((index) => bytes[index] == expected[index])) {
      throw const FormatException(
        'Export changed. Only the exact fixed starter passes source verification.',
      );
    }
    snapshot[entry.key] = bytes;
  }
  check();
  return snapshot;
}
