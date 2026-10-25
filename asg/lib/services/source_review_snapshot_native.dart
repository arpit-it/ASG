import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import '../models/source_edit_proposal.dart';
import '../models/source_generation.dart';

/// Reads only selected recorded source for review; never writes or runs tools.
/// Hashes describe these captured bytes, not a lock on later filesystem changes.
Future<Map<String, String>> readSourceReviewSnapshot(
  GeneratedProject project,
  List<String> selectedPaths,
) {
  final selected = List<String>.unmodifiable(selectedPaths);
  return Isolate.run(() {
    if (selected.isEmpty ||
        selected.length > SourceEditProposal.maxFiles ||
        selected.toSet().length != selected.length ||
        selected.any((p) => !SourceEditProposal.isSourcePath(p))) {
      throw const FormatException('Select 1–8 distinct lib/test Dart files.');
    }
    final root = project.directory;
    void checkPath(String relative) {
      if (!path.isAbsolute(root) ||
          Directory(root).resolveSymbolicLinksSync() != root) {
        throw StateError('Generated project path changed.');
      }
      var current = root;
      final parts = relative.split('/');
      for (var i = 0; i < parts.length; i++) {
        current = path.join(current, parts[i]);
        final expected = i == parts.length - 1
            ? FileSystemEntityType.file
            : FileSystemEntityType.directory;
        if (FileSystemEntity.typeSync(current, followLinks: false) !=
            expected) {
          throw StateError('Source file is missing, linked or unsupported.');
        }
      }
    }

    final result = <String, String>{};
    for (final relative in selected) {
      final expected = project.sources[relative];
      if (expected == null) {
        throw StateError('Source file is not in the saved generated project.');
      }
      checkPath(relative);
      final file = File(path.join(root, relative)).openSync();
      late List<int> bytes;
      try {
        // Four bytes per allowed UTF-16 code unit is a conservative UTF-8 cap.
        final maximum = SourceEditProposal.maxText * 4;
        if (file.lengthSync() > maximum) {
          throw const FormatException('Source file is too large for review.');
        }
        bytes = file.readSync(maximum + 1);
        if (bytes.length > maximum ||
            file.positionSync() != file.lengthSync()) {
          throw const FormatException('Source file grew during review.');
        }
      } finally {
        file.closeSync();
      }
      checkPath(relative);
      if (sha256.convert(bytes).toString() != expected) {
        throw StateError('Source changed since the saved generated project.');
      }
      final text = utf8.decode(bytes);
      if (text.length > SourceEditProposal.maxText) {
        throw const FormatException('Source file is too large for review.');
      }
      result[relative] = text;
      if (jsonEncode(result).length > SourceEditProposal.maxResponse) {
        throw const FormatException('Selected source exceeds review bounds.');
      }
    }
    return Map<String, String>.unmodifiable(result);
  });
}
