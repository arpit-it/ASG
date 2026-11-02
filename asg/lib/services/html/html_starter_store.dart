// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import '../../models/html/saved_html_starter.dart';
import '../record_storage.dart';

class HtmlStarterStore {
  HtmlStarterStore(this.records);
  final RecordStorage records;
  static const key = 'studio.htmlStarters.v1';

  List<SavedHtmlStarter> load() => _decode(records.getString(key));

  List<SavedHtmlStarter> _decode(String? raw) {
    if (raw == null) return const [];
    if (raw.length > 1500000) {
      throw const FormatException('Starter library too large.');
    }
    final value = jsonDecode(raw);
    if (value is! List || value.length > 100) {
      throw const FormatException('Invalid starter library.');
    }
    final result = value.map(SavedHtmlStarter.fromJson).toList();
    if (result.map((s) => s.directory).toSet().length != result.length) {
      throw const FormatException('Duplicate starter identity.');
    }
    return List.unmodifiable(result);
  }

  /// Conditional durable publication prevents lost writes across library owners.
  /// A conflict is a retryable failure, never silent replacement of other data.
  Future<void> save(SavedHtmlStarter starter) async {
    final storage = records;
    if (storage is! ConditionalRecordStorage) {
      throw UnsupportedError(
        'Starter saving requires transactional local storage.',
      );
    }
    final before = storage.getString(key);
    final entries = _decode(before);
    final existing = entries
        .where((s) => s.directory == starter.directory)
        .firstOrNull;
    if (existing != null) {
      if (jsonEncode(existing.toJson()) != jsonEncode(starter.toJson())) {
        throw StateError(
          'This destination already has different saved inputs.',
        );
      }
      return;
    }
    if (entries.length >= 100) throw StateError('Starter library is full.');
    await storage.commitRecords(
      expected: {key: before},
      updates: {
        key: jsonEncode([...entries, starter].map((s) => s.toJson()).toList()),
      },
      authorize: () {},
    );
  }
}
