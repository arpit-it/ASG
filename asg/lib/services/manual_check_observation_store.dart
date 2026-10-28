// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import '../models/manual_check_observation.dart';
import 'record_storage.dart';

/// Latest observation per authored check; no command output or inferred results.
class ManualCheckObservationStore {
  ManualCheckObservationStore(this.records);
  final RecordStorage records;
  static String key(String projectId) => 'studio.manualChecks.v1.$projectId';
  static List<ManualCheckObservation> decode(String raw) {
    final json = jsonDecode(raw);
    if (json is! Map<String, dynamic> ||
        json.length != 2 ||
        json['version'] != 1 ||
        json['observations'] is! List ||
        (json['observations'] as List).length > 1000) {
      throw const FormatException('Invalid manual check record.');
    }
    final values = (json['observations'] as List)
        .map(
          (value) =>
              ManualCheckObservation.fromJson(value as Map<String, dynamic>),
        )
        .toList();
    final ids = <String>{};
    for (final value in values) {
      if (!ids.add('${value.requirementId}/${value.checkId}')) {
        throw const FormatException('Duplicate manual check observation.');
      }
    }
    return List.unmodifiable(values);
  }

  List<ManualCheckObservation> load(String projectId) {
    final raw = records.getString(key(projectId));
    if (raw == null) return const [];
    try {
      return decode(raw);
    } catch (_) {
      throw const FormatException(
        'Saved manual observations are unreadable; records have not been replaced.',
      );
    }
  }

  static String encode(List<ManualCheckObservation> values) {
    final raw = jsonEncode({
      'version': 1,
      'observations': [for (final value in values) value.toJson()],
    });
    decode(raw);
    return raw;
  }
}
