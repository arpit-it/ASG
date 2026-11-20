// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'imported_commit_context.dart';
import 'imported_commit_source_observation.dart';
import 'imported_plan.dart';
import 'imported_source_proposal.dart';
import 'source_line_diff.dart';

/// Supplied immutable-context review data, never an applicable patch, current
/// approval, working-file observation or source copy/write/execution grant.
final class ImportedCommitProposal {
  ImportedCommitProposal._(
    this.root,
    this.contextDigest,
    this.planDigest,
    this.source,
    this.replacement,
    this.afterHash,
    this.afterByteLength,
    this.recordJson,
    this.digest,
    this.diff,
  );

  // Share only the established pure preview text policy, not its working-source
  // context, record schema, storage key or approval interpretation.
  static const textByteLimit = ImportedSourceProposal.textByteLimit;
  static const lineLimit = ImportedSourceProposal.lineLimit;
  static const recordByteLimit = 64 * 1024;
  static bool validText(String value) =>
      ImportedSourceProposal.validText(value);

  final String root, contextDigest, planDigest, replacement, afterHash;
  final ImportedCommitSourceFile source;
  final int afterByteLength;
  final String recordJson, digest;
  final SourceLineDiff diff;
  bool get sourceVerified => false;
  String get workingTree => 'unknown';
  String get conflict => 'unknown';
  bool matches(ImportedCommitProposal other) => recordJson == other.recordJson;

  /// The caller separately binds the supplied plan to current durable app inputs.
  /// A caller-provided approved flag is not evidence of current review consent.
  factory ImportedCommitProposal.create({
    required ImportedCommitContext context,
    required ImportedPlan plan,
    required String path,
    required String replacement,
  }) {
    try {
      ImportedPlan.validateText(plan.text);
      var planText = utf8.decode(utf8.encode(plan.text));
      if (plan.text.startsWith('\ufeff')) planText = '\ufeff$planText';
      if (!plan.approved ||
          plan.context != context.recordJson ||
          planText != plan.text ||
          !validText(replacement)) {
        throw const FormatException();
      }
      final source = context.files.singleWhere((f) => f.source.path == path);
      if (!validText(source.source.text) || source.source.text == replacement) {
        throw const FormatException();
      }
      final metadata = jsonDecode(context.recordJson)['metadata'] as Map;
      final root = metadata['root'] as String;
      final planDigest = sha256
          .convert(utf8.encode(jsonEncode(plan.toJson())))
          .toString();
      final bytes = utf8.encode(replacement);
      final afterHash = sha256.convert(bytes).toString();
      final record = jsonEncode({
        'version': 1,
        'scope': 'imported-commit-proposal',
        'source_verified': false,
        'working_tree': 'unknown',
        'conflict': 'unknown',
        'root': root,
        'context_sha256': context.digest,
        'plan_sha256': planDigest,
        'commit': context.commit,
        'tree': context.tree,
        'manifest_sha256': context.manifestDigest,
        'path': source.source.path,
        'before_mode': source.mode,
        'before_git_blob': source.gitBlob,
        'before_sha256': source.source.digest,
        'before_byte_length': source.source.byteLength,
        'after_sha256': afterHash,
        'after_byte_length': bytes.length,
        'replacement': replacement,
      });
      if (utf8.encode(record).length > recordByteLimit) {
        throw const FormatException();
      }
      return ImportedCommitProposal._(
        root,
        context.digest,
        planDigest,
        source,
        replacement,
        afterHash,
        bytes.length,
        record,
        sha256.convert(utf8.encode(record)).toString(),
        SourceLineDiff.compare(source.source.text, replacement),
      );
    } catch (_) {
      throw const FormatException(
        'Committed source proposal inputs are invalid or exceed local preview limits.',
      );
    }
  }
}
