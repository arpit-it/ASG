// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../models/html/html_source_draft.dart';
import '../record_storage.dart';

class HtmlSourceDraftStore {
  HtmlSourceDraftStore(this.records, this.projectId);
  final RecordStorage records;
  final String projectId;
  static const prefix = 'studio.htmlSourceDraft.v1.';
  String get key => '$prefix$projectId';

  static String digest(Map<String, String?> context) =>
      sha256.convert(utf8.encode(jsonEncode(context))).toString();

  HtmlSourceDraft? load() {
    final raw = records.getString(key);
    if (raw == null) return null;
    final draft = HtmlSourceDraft.decode(raw);
    if (draft.projectId != projectId) {
      throw const FormatException('Saved HTML draft identity mismatch.');
    }
    return draft;
  }

  Future<void> save(
    HtmlSourceDraft draft, {
    required Map<String, String?> context,
    required void Function() authorize,
  }) async {
    final storage = records;
    if (storage is! ConditionalRecordStorage) {
      throw UnsupportedError('Drafts require transactional storage.');
    }
    final previous = storage.getString(key);
    load(); // Preserve corrupt or mismatched records rather than replacing them.
    if (draft.projectId != projectId ||
        draft.contextDigest != digest(context)) {
      throw StateError('Draft context mismatch.');
    }
    final value = draft.encode();
    authorize();
    await storage.commitRecords(
      expected: {...context, key: previous},
      updates: {key: value},
      authorize: authorize,
    );
  }
}
