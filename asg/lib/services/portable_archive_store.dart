// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/portable_project_archive.dart';
import 'record_storage.dart';

/// Durable data-only copies, isolated from executable project records.
/// IDs belong to the application, never to an untrusted archive manifest.
class PortableArchiveStore {
  PortableArchiveStore(this.records);
  final ConditionalRecordStorage records;

  static String key(String id) {
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}$').hasMatch(id)) {
      throw const FormatException(
        'Use a backup ID of 1–80 letters, digits, underscores or hyphens.',
      );
    }
    return 'studio.archive.v1.$id';
  }

  PortableProjectArchive? load(String id) {
    final raw = records.getString(key(id));
    return raw == null ? null : PortableProjectArchive.decode(raw);
  }

  /// Validates before writing and refuses every existing target, including
  /// corrupt records. The conditional transaction also guards concurrent calls.
  /// Returns only after the complete copy commits; never grants plan consent.
  Future<PortableProjectArchive> restoreCopy(String id, String encoded) async {
    final target = key(id);
    final archive = PortableProjectArchive.decode(encoded);
    final canonical = archive.encode();
    if (records.getString(target) != null) {
      throw StateError('Backup ID already exists. Choose a new ID.');
    }
    await records.commitRecords(
      expected: {target: null},
      updates: {target: canonical},
      authorize: () {},
    );
    return archive;
  }
}
