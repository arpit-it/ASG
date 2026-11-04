// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../../models/html/html_source_proposal.dart';
import 'html_reviewed_source_check.dart';

/// Bounded, read-only snapshot on a cooperative filesystem. Concurrent local
/// actors are outside this identity check's protection; it is not a sandbox.
class NativeHtmlReviewedSourceChecker implements HtmlReviewedSourceChecker {
  @override
  bool get supported => Platform.isMacOS;

  @override
  Future<HtmlReviewedSourceCheck> check({
    required String directory,
    required HtmlSourceProposal proposal,
    required void Function() authorizeRead,
  }) async {
    if (!supported) {
      throw UnsupportedError('Reviewed source identity requires macOS.');
    }
    Future<void> checkDirectory() async {
      authorizeRead();
      if (!path.isAbsolute(directory) ||
          await Directory(directory).resolveSymbolicLinks() !=
              path.normalize(directory)) {
        throw const FormatException('Choose a real absolute export directory.');
      }
      authorizeRead();
    }

    Future<void> checkEntries() async {
      await checkDirectory();
      final names = <String>{};
      // Stream with a bounded count: never materialize an arbitrary directory.
      await for (final entity in Directory(
        directory,
      ).list(followLinks: false)) {
        authorizeRead();
        final name = path.basename(entity.path);
        if (!proposal.files.containsKey(name) || !names.add(name)) {
          throw const FormatException('Unexpected exported source entry.');
        }
      }
      if (names.length != proposal.files.length) {
        throw const FormatException('Exported source file is missing.');
      }
      authorizeRead();
    }

    await checkEntries();
    var total = 0;
    for (final entry in proposal.files.entries) {
      await checkDirectory();
      final file = File(path.join(directory, entry.key));
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await file.resolveSymbolicLinks() != file.path) {
        throw const FormatException('Exported source is missing or symbolic.');
      }
      final expected = utf8.encode(entry.value);
      authorizeRead();
      final reader = await file.open();
      late List<int> actual;
      try {
        authorizeRead();
        actual = await reader.read(expected.length + 1);
      } finally {
        await reader.close();
      }
      authorizeRead();
      if (actual.length != expected.length ||
          !Iterable<int>.generate(expected.length)
              .every((index) => expected[index] == actual[index])) {
        throw const FormatException('Exported source changed.');
      }
      total += actual.length;
    }
    await checkEntries();
    return HtmlReviewedSourceCheck(files: proposal.files.length, bytes: total);
  }
}

HtmlReviewedSourceChecker createHtmlReviewedSourceChecker() =>
    NativeHtmlReviewedSourceChecker();
