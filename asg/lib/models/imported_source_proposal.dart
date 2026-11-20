// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'imported_plan.dart';
import 'imported_source_context.dart';
import 'project_source_observation.dart';
import 'source_line_diff.dart';

/// Transient review data, never a patch, write grant or current-disk observation.
/// Callers must separately recheck current app inputs and the exact saved plan.
final class ImportedSourceProposal {
  ImportedSourceProposal._(
    this.root,
    this.contextDigest,
    this.planDigest,
    this.source,
    this.replacement,
    this.afterHash,
    this.recordJson,
    this.digest,
    this.diff,
  );
  static const textByteLimit = 16 * 1024,
      lineLimit = 500,
      recordByteLimit = 64 * 1024;
  final String root,
      contextDigest,
      planDigest,
      replacement,
      afterHash,
      recordJson,
      digest;
  final ProjectSourceFile source;
  final SourceLineDiff diff;
  bool get sourceVerified => false;
  bool matches(ImportedSourceProposal other) => recordJson == other.recordJson;

  static bool validText(String value) {
    if (value.length > textByteLimit) return false;
    final bytes = utf8.encode(value);
    if (bytes.length > textByteLimit) return false;
    var decoded = utf8.decode(bytes);
    if (bytes.length >= 3 &&
        bytes[0] == 239 &&
        bytes[1] == 187 &&
        bytes[2] == 191) {
      decoded = '\ufeff$decoded';
    }
    if (decoded != value ||
        value.runes.any(
          (r) => (r < 32 && !{9, 10, 13}.contains(r)) || (r >= 127 && r <= 159),
        )) {
      return false;
    }
    final lines = value.isEmpty
        ? 0
        : value.split(RegExp(r'\r\n|[\r\n\u2028\u2029]')).length -
              (RegExp(r'(\r\n|[\r\n\u2028\u2029])$').hasMatch(value) ? 1 : 0);
    return lines <= lineLimit;
  }

  factory ImportedSourceProposal.create({
    required ImportedSourceContext context,
    required ImportedPlan plan,
    required String path,
    required String replacement,
  }) {
    try {
      ImportedPlan.validateText(plan.text);
      if (!plan.approved ||
          plan.context != context.recordJson ||
          !validText(replacement)) {
        throw const FormatException();
      }
      final source = context.files.singleWhere((f) => f.path == path);
      if (!validText(source.text) || source.text == replacement) {
        throw const FormatException();
      }
      final metadata = jsonDecode(context.recordJson)['metadata'] as Map;
      final root = metadata['root'] as String;
      final planDigest = sha256
          .convert(utf8.encode(jsonEncode(plan.toJson())))
          .toString();
      final afterHash = sha256.convert(utf8.encode(replacement)).toString();
      final record = jsonEncode({
        'version': 1,
        'scope': 'imported-source-proposal',
        'source_verified': false,
        'root': root,
        'context_sha256': context.digest,
        'plan_sha256': planDigest,
        'path': source.path,
        'before_sha256': source.digest,
        'after_sha256': afterHash,
        'replacement': replacement,
      });
      if (utf8.encode(record).length > recordByteLimit) {
        throw const FormatException();
      }
      return ImportedSourceProposal._(
        root,
        context.digest,
        planDigest,
        source,
        replacement,
        afterHash,
        record,
        sha256.convert(utf8.encode(record)).toString(),
        SourceLineDiff.compare(source.text, replacement),
      );
    } catch (_) {
      throw const FormatException(
        'Imported source proposal inputs are invalid or exceed local preview limits.',
      );
    }
  }
}
