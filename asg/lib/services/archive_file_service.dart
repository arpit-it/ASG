import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';

import '../models/portable_project_archive.dart';

/// File dialogs never import records themselves. Reads are bounded even when a
/// file changes size after selection; malformed UTF-8 is rejected.
class ArchiveFileService {
  bool get canExport =>
      !kIsWeb &&
      const [
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
      ].contains(defaultTargetPlatform);

  Future<String?> pickImport() async {
    final file = await openFile();
    if (file == null) return null;
    if (await file.length() > PortableProjectArchive.maxBytes) {
      throw const FormatException('Archive exceeds the 1 MiB limit.');
    }
    return readBounded(file.openRead());
  }

  static Future<String> readBounded(Stream<List<int>> stream) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      if (bytes.length + chunk.length > PortableProjectArchive.maxBytes) {
        throw const FormatException('Archive exceeds the 1 MiB limit.');
      }
      bytes.add(chunk);
    }
    return utf8.decode(bytes.takeBytes());
  }

  /// False means the user cancelled, not that a file was written.
  Future<bool> export(String encoded) async {
    if (!canExport) {
      throw UnsupportedError('Archive file export requires a desktop app.');
    }
    PortableProjectArchive.decode(encoded);
    final location = await getSaveLocation(suggestedName: 'asg-records.json');
    if (location == null) return false;
    await XFile.fromData(
      Uint8List.fromList(utf8.encode(encoded)),
      mimeType: 'application/json',
      name: 'asg-records.json',
    ).saveTo(location.path);
    return true;
  }
}
