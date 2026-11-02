// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:io';

import 'package:path/path.dart' as path;

import '../../models/html/html_export_request.dart';
import 'html_site_template.dart';

/// Fixed-source export only; no model input, shell, verification or preview.
/// The caller owns confirmation and must revalidate current session authority
/// in [authorizeWrite]. This is not a sandbox against concurrent local actors.
class HtmlSourceExportNative {
  bool get supported => Platform.isMacOS;

  Future<String> export({
    required HtmlExportRequest request,
    required HtmlExportRequest? confirmedRequest,
    required void Function() authorizeWrite,
  }) async {
    void check() {
      if (!supported) {
        throw UnsupportedError(
          'HTML source export is available on macOS only.',
        );
      }
      if (confirmedRequest == null || !request.matches(confirmedRequest)) {
        throw StateError(
          'Confirm the exact HTML content and destination first.',
        );
      }
      authorizeWrite();
    }

    check();
    if (!path.isAbsolute(request.parent) ||
        !RegExp(r'^[a-z][a-z0-9_]{2,50}$').hasMatch(request.folderName)) {
      throw const FormatException(
        'Choose an absolute parent and a new 3–51 character lowercase folder name.',
      );
    }
    final parent = await Directory(request.parent).resolveSymbolicLinks();
    if (parent != path.normalize(request.parent)) {
      throw const FormatException('Choose a real parent, not a symbolic link.');
    }
    final destination = path.join(parent, request.folderName);
    if (await FileSystemEntity.type(destination, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw StateError('Destination already exists; nothing was overwritten.');
    }
    final sources = HtmlSiteTemplate().generate(request.input);
    check();
    // Unlike Directory.create, mkdir refuses an existing directory atomically.
    final created = await Process.run('/bin/mkdir', [
      '-m',
      '700',
      destination,
    ], runInShell: false).timeout(const Duration(seconds: 5));
    if (created.exitCode != 0) {
      throw StateError(
        'Could not create a new export folder; nothing overwritten.',
      );
    }
    try {
      Future<void> checkDirectory(String directory) async {
        check();
        if (await Directory(directory).resolveSymbolicLinks() != directory ||
            await Directory(parent).resolveSymbolicLinks() != parent) {
          throw StateError('Export path changed.');
        }
        check();
      }

      await checkDirectory(destination);
      check();
      // Only the fixed template's one known subdirectory can be created.
      await Directory(path.join(destination, 'assets')).create();
      for (final entry in sources.entries) {
        await checkDirectory(destination);
        final file = File(path.join(destination, entry.key));
        await checkDirectory(file.parent.path);
        check();
        await file.create(exclusive: true);
        // Recheck following the async create before opening for content writes.
        await checkDirectory(file.parent.path);
        if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file) {
          throw StateError('Export file changed.');
        }
        check();
        await file.writeAsString(entry.value, flush: true);
      }
      await checkDirectory(destination);
      return destination;
    } catch (_) {
      // Never delete a path which another actor could have changed or report a
      // partially written directory as a successful, runnable project.
      throw HtmlExportFailure(destination);
    }
  }
}
