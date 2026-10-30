// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/local_model_config.dart';
import '../models/source_edit_proposal.dart';
import '../models/structured_proposal_json.dart';
import 'local_model.dart';
import 'model_provider.dart';

/// Requests review artifacts. It never reads files, applies edits or runs code.
class SourceEditProposer {
  SourceEditProposer({ProviderFactory? createProvider})
    : _createProvider =
          createProvider ??
          ((config) => LocalModelProvider(config, maxTokens: 4096));

  final ProviderFactory _createProvider;
  ModelProvider? _provider;
  bool _active = false, _cancelled = false;

  Future<SourceEditProposal> propose({
    required LocalModelConfig config,
    required String instruction,
    required Map<String, String> originals,
  }) async {
    if (_active) throw StateError('A source proposal is already active.');
    final snapshot = Map<String, String>.unmodifiable(originals);
    if (instruction.trim().isEmpty ||
        instruction.length > 8000 ||
        snapshot.isEmpty ||
        snapshot.length > SourceEditProposal.maxFiles ||
        snapshot.entries.any(
          (e) =>
              !SourceEditProposal.isSourcePath(e.key) ||
              e.value.length > SourceEditProposal.maxText,
        ) ||
        jsonEncode(snapshot).length > SourceEditProposal.maxResponse) {
      throw const FormatException('Invalid source proposal input bounds.');
    }
    _active = true;
    _cancelled = false;
    late SourceEditProposal result;
    try {
      final provider = _createProvider(config);
      _provider = provider;
      final fingerprints = {
        for (final entry in snapshot.entries)
          entry.key: sha256.convert(utf8.encode(entry.value)).toString(),
      };
      final prompt =
          'Propose Flutter Dart replacements for review. Return JSON only '
          'with exactly summary (short string) and changes (1-8 entries). Each '
          'change has exactly path, beforeSha256, after (full replacement text). '
          'Copy beforeSha256 verbatim from Fingerprints for that path; do not '
          'compute it or return before text. One entry per path. '
          'after MUST be the COMPLETE FILE, not a snippet, search/replace '
          'fragment, diff or individual line. '
          'Preserve existing license identifiers and copyright headers verbatim '
          'at the beginning of after, including during build repairs. '
          'Preserve unrelated code and imports. Only change supplied files. '
          'No commands or new files. '
          'Instruction: ${jsonEncode(instruction)}. '
          'Fingerprints: ${jsonEncode(fingerprints)}. '
          'Originals: ${jsonEncode(snapshot)}';
      final buffer = StringBuffer();
      await for (final chunk in provider.generate(prompt)) {
        if (_cancelled) throw StateError('Source proposal cancelled.');
        if (buffer.length + chunk.length > SourceEditProposal.maxResponse) {
          throw const FormatException('Source proposal response is too large.');
        }
        buffer.write(chunk);
      }
      if (_cancelled) throw StateError('Source proposal cancelled.');
      final json = buffer.toString();
      final decoded = jsonDecode(json);
      // Decode first so the member scanner only receives valid JSON. Reject
      // ambiguous keys before the decoder's last value can become a proposal.
      rejectDuplicateJsonMembers(json);
      result = SourceEditProposal.parse(
        _hydrateOriginals(decoded, snapshot, fingerprints),
        originals: snapshot,
      );
    } finally {
      try {
        await _provider?.cancel();
      } finally {
        _provider = null;
        _active = false;
      }
    }
    if (_cancelled) throw StateError('Source proposal cancelled.');
    return result;
  }

  /// Hydrate exact review text only after validating the model's snapshot token.
  /// Legacy full-before responses still pass through the strict domain parser.
  Object? _hydrateOriginals(
    Object? decoded,
    Map<String, String> snapshot,
    Map<String, String> fingerprints,
  ) {
    if (decoded is! Map || decoded['changes'] is! List) return decoded;
    final changes = <Object?>[];
    for (final entry in decoded['changes'] as List) {
      if (entry is! Map || !entry.containsKey('beforeSha256')) {
        changes.add(entry);
        continue;
      }
      final path = entry['path'];
      if (entry.length != 3 ||
          !entry.containsKey('after') ||
          path is! String ||
          !snapshot.containsKey(path) ||
          entry['beforeSha256'] is! String ||
          entry['beforeSha256'] != fingerprints[path]) {
        throw const FormatException('Invalid or stale source fingerprint.');
      }
      changes.add({
        'path': path,
        'before': snapshot[path],
        'after': entry['after'],
      });
    }
    return {...decoded, 'changes': changes};
  }

  Future<void> cancel() async {
    if (!_active) return;
    _cancelled = true;
    await _provider?.cancel();
  }
}
