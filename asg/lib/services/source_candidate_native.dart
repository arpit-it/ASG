// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import '../models/source_edit_proposal.dart';
import '../models/source_generation.dart';

/// Snapshot preparation, not a sandbox against hostile same-user mutations.
/// Failed candidates are retained; the original and its preview are never written.
Future<GeneratedProject> prepareCandidateFiles({
  required GeneratedProject generated,
  required SourceEditProposal proposal,
  required String parent,
  required void Function() authorizeWrite,
}) async {
  authorizeWrite();
  final files = await _captureIsolated(generated, proposal);
  authorizeWrite();
  final root = generated.directory;
  if (!path.isAbsolute(parent) ||
      await Directory(parent).resolveSymbolicLinks() != parent ||
      parent == root ||
      path.isWithin(root, parent)) {
    throw StateError('Choose a real candidate parent outside the original.');
  }
  authorizeWrite();
  // OS-created unique directory: existing folders and files cannot be replaced.
  final destination = await Directory(parent).createTemp('asg-candidate-');
  void checkDestination([String? relative]) {
    authorizeWrite();
    if (destination.resolveSymbolicLinksSync() != destination.path) {
      throw StateError('Candidate directory changed.');
    }
    var current = destination.path;
    final parts = relative?.split('/') ?? <String>[];
    for (final part in parts.take(parts.isNotEmpty ? parts.length - 1 : 0)) {
      current = path.join(current, part);
      if (FileSystemEntity.typeSync(current, followLinks: false) !=
          FileSystemEntityType.directory) {
        throw StateError('Candidate parent changed.');
      }
    }
  }

  try {
    for (final entry in files.entries) {
      checkDestination();
      var folder = destination.path;
      final parts = entry.key.split('/');
      for (final part in parts.take(parts.length - 1)) {
        folder = path.join(folder, part);
        final type = FileSystemEntity.typeSync(folder, followLinks: false);
        if (type == FileSystemEntityType.notFound) {
          await Directory(folder).create();
          checkDestination();
        } else if (type != FileSystemEntityType.directory) {
          throw StateError('Candidate contains a linked or invalid folder.');
        }
      }
      checkDestination(entry.key);
      final file = File(path.join(destination.path, entry.key));
      await file.create(exclusive: true);
      checkDestination(entry.key);
      if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw StateError('Candidate file changed.');
      }
      await file.writeAsBytes(entry.value, flush: true);
    }
    checkDestination();
    return GeneratedProject(
      directory: destination.path,
      sdk: generated.sdk,
      python: generated.python,
      sources: {
        for (final entry in files.entries)
          entry.key: sha256.convert(entry.value).toString(),
      },
    );
  } catch (error) {
    // Do not recursively delete a path whose ownership may have changed.
    throw StateError(
      'Candidate preparation failed; original retained. '
      'Partial candidate: ${destination.path}. $error',
    );
  }
}

// Separate closure context: never capture the caller's authorization callback,
// controller, or database handles in the message sent to the worker isolate.
Future<Map<String, List<int>>> _captureIsolated(
  GeneratedProject generated,
  SourceEditProposal proposal,
) => Isolate.run(() => _capture(generated, proposal));

Map<String, List<int>> _capture(
  GeneratedProject generated,
  SourceEditProposal proposal,
) {
  const maxFiles = 64, maxFileBytes = 512 * 1024, maxBytes = 2 * 1024 * 1024;
  final root = generated.directory;
  if (!path.isAbsolute(root) ||
      Directory(root).resolveSymbolicLinksSync() != root) {
    throw StateError('Original project directory changed.');
  }
  final expected = generated.sources;
  bool allowed(String relative) {
    final parts = relative.split('/');
    return parts.length <= 16 &&
        !['build', '.dart_tool', 'pubspec.lock'].contains(parts.first) &&
        parts.every(
          (part) =>
              part != '.' &&
              part != '..' &&
              RegExp(r'^[a-zA-Z0-9_.-]+$').hasMatch(part) &&
              (!part.startsWith('.') || relative == '.gitignore'),
        );
  }

  if (expected.isEmpty ||
      expected.length > maxFiles ||
      expected.keys.any((key) => !allowed(key))) {
    throw const FormatException('Unsupported candidate source manifest.');
  }
  final files = <String, List<int>>{};
  var total = 0, directories = 0;
  void visit(Directory folder) {
    if (++directories > 128) {
      throw const FormatException('Too many candidate source directories.');
    }
    for (final entity in folder.listSync(followLinks: false)) {
      final relative = path
          .relative(entity.path, from: root)
          .replaceAll(path.separator, '/');
      if (entity is Link) throw StateError('Linked project entries refused.');
      if (['build', '.dart_tool', 'pubspec.lock'].contains(relative)) continue;
      if (!allowed(relative)) {
        throw StateError('Unsupported candidate source path.');
      }
      if (entity is Directory) {
        visit(entity);
      } else if (entity is File && expected.containsKey(relative)) {
        final file = entity.openSync();
        late List<int> bytes;
        try {
          if (file.lengthSync() > maxFileBytes) {
            throw const FormatException(
              'Candidate source file exceeds bounds.',
            );
          }
          bytes = file.readSync(maxFileBytes + 1);
          if (bytes.length > maxFileBytes ||
              file.positionSync() != file.lengthSync()) {
            throw const FormatException(
              'Candidate source grew during capture.',
            );
          }
        } finally {
          file.closeSync();
        }
        total += bytes.length;
        if (total > maxBytes) {
          throw const FormatException('Candidate exceeds bounds.');
        }
        if (sha256.convert(bytes).toString() != expected[relative]) {
          throw StateError('Original source changed since generation.');
        }
        files[relative] = bytes;
      } else {
        throw StateError('Unrecorded or unsupported source entry.');
      }
    }
  }

  visit(Directory(root));
  if (files.length != expected.length) {
    throw StateError('Recorded source is missing.');
  }
  for (final change in proposal.changes) {
    final bytes = files[change.path];
    if (bytes == null || utf8.decode(bytes) != change.before) {
      throw StateError('Proposal original no longer matches source.');
    }
    files[change.path] = utf8.encode(change.after);
  }
  return files;
}
