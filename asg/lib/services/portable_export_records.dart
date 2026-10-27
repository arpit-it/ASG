// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import '../models/structured_proposal_json.dart';
import 'record_storage.dart';

/// Checks source JSON before repository decoding can collapse duplicate fields.
/// Only records actually read for export are inspected; nothing is modified.
class PortableExportRecords implements RecordStorage {
  PortableExportRecords(this.records);
  final RecordStorage records;

  @override
  String? getString(String key) {
    final raw = records.getString(key);
    if (raw != null) {
      jsonDecode(raw); // The duplicate-member scanner requires valid syntax.
      rejectDuplicateJsonMembers(raw);
    }
    return raw;
  }

  @override
  Future<bool> setString(String key, String value) =>
      throw UnsupportedError('Portable export records are read-only.');
}
