// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';

import '../models/portable_project_archive.dart';

/// File dialogs never import records themselves. Reads are bounded even when a
/// file changes size after selection; malformed UTF-8 is rejected.
class ArchiveFileService {
  static const readTimeout = Duration(seconds: 15);
  bool get canExport =>
      kIsWeb ||
      const [
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
      ].contains(defaultTargetPlatform);

  String get exportButtonLabel =>
      kIsWeb ? 'Download archive file' : 'Choose export file';

  String get exportSuccessMessage => kIsWeb
      ? 'Download requested. Check your browser downloads to confirm the file was saved.'
      : 'Archive file saved.';

  Future<String?> pickImport() async {
    final file = await openFile();
    if (file == null) return null;
    if (await file.length().timeout(readTimeout) >
        PortableProjectArchive.maxBytes) {
      throw const FormatException('Archive exceeds the 1 MiB limit.');
    }
    return readBounded(file.openRead());
  }

  /// A whole-read deadline also bounds a provider that trickles small chunks.
  /// Cancellation is requested without awaiting provider cleanup, which itself
  /// may stall. A timed-out read can never publish its partial bytes.
  static Future<String> readBounded(
    Stream<List<int>> stream, {
    Duration timeout = readTimeout,
  }) async {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'Must be positive.');
    }
    final iterator = StreamIterator(stream);
    Future<String> read() async {
      // Providers may reuse a Uint8List for later chunks. Own each chunk
      // before requesting another event so earlier archive bytes stay exact.
      final bytes = BytesBuilder();
      try {
        while (await iterator.moveNext()) {
          final chunk = iterator.current;
          if (bytes.length + chunk.length > PortableProjectArchive.maxBytes) {
            throw const FormatException('Archive exceeds the 1 MiB limit.');
          }
          // BytesBuilder truncates integers to eight bits. Refuse malformed
          // provider data before it can normalize into a different archive.
          if (chunk.any((byte) => byte < 0 || byte > 255)) {
            throw const FormatException(
              'Archive contains invalid byte values.',
            );
          }
          bytes.add(chunk);
        }
        return utf8.decode(bytes.takeBytes());
      } finally {
        // Cleanup failure cannot turn a failed read into a successful import.
        iterator.cancel().ignore();
      }
    }

    return read().timeout(
      timeout,
      onTimeout: () {
        iterator.cancel().ignore();
        throw TimeoutException('Archive file read timed out. Select it again.');
      },
    );
  }

  /// False means native dialog cancellation. Web success means download requested.
  Future<bool> export(String encoded) async {
    if (!canExport) {
      throw UnsupportedError(
        'Archive file export requires a desktop app or browser.',
      );
    }
    PortableProjectArchive.decode(encoded);
    final file = XFile.fromData(
      Uint8List.fromList(utf8.encode(encoded)),
      mimeType: 'application/json',
      name: 'asg-records.json',
    );
    // Web saveTo requests a Blob download; browsers own its final destination
    // and completion. Native desktop keeps the explicit save/cancel dialog.
    if (kIsWeb) {
      await file.saveTo('asg-records.json');
      return true;
    }
    final location = await getSaveLocation(suggestedName: 'asg-records.json');
    if (location == null) return false;
    await file.saveTo(location.path);
    return true;
  }
}
