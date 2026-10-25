import 'dart:convert';

import '../models/local_model_config.dart';
import '../models/source_edit_proposal.dart';
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
      final prompt =
          'Propose Flutter Dart replacements for review. Return JSON only '
          'with exactly summary (short string) and changes (1-8 entries). Each '
          'change has exactly path, before (exact original text), after (full '
          'replacement text). Only change supplied files. No commands or new files. '
          'Instruction: ${jsonEncode(instruction)}. Originals: ${jsonEncode(snapshot)}';
      final buffer = StringBuffer();
      await for (final chunk in provider.generate(prompt)) {
        if (_cancelled) throw StateError('Source proposal cancelled.');
        if (buffer.length + chunk.length > SourceEditProposal.maxResponse) {
          throw const FormatException('Source proposal response is too large.');
        }
        buffer.write(chunk);
      }
      if (_cancelled) throw StateError('Source proposal cancelled.');
      result = SourceEditProposal.parse(
        jsonDecode(buffer.toString()),
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

  Future<void> cancel() async {
    if (!_active) return;
    _cancelled = true;
    await _provider?.cancel();
  }
}
