// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import '../../models/html/html_source_proposal.dart';
import '../../models/local_model_config.dart';
import '../../models/model_request_provenance.dart';
import '../local_model.dart';
import '../model_provider.dart';

/// Streams an untrusted review artifact; never writes or serves model code.
/// The caller owns request deadlines and calls cancel on disposal. Cancellation
/// revokes the result immediately; ownership lasts until stream/cleanup settle.
class HtmlSourceProposer {
  HtmlSourceProposer({ProviderFactory? createProvider})
    : _createProvider =
          createProvider ??
          ((config) => LocalModelProvider(
            config,
            maxTokens: ModelRequestProvenance.sourceOutputTokens,
          ));

  final ProviderFactory _createProvider;
  ModelProvider? _provider;
  bool _active = false, _cancelled = false;

  Future<HtmlSourceProposal> propose({
    required LocalModelConfig config,
    required String instruction,
  }) async {
    if (_active) throw StateError('An HTML source proposal is already active.');
    if (instruction.trim().isEmpty || instruction.length > 8000) {
      throw const FormatException('Use 1–8000 instruction characters.');
    }
    _active = true;
    _cancelled = false;
    late HtmlSourceProposal result;
    try {
      final provider = _createProvider(config);
      _provider = provider;
      final prompt =
          'Create independent HTML/CSS sources for review. '
          'Return JSON only with exactly summary (short string) and files '
          '(an object with required index.html and styles.css, optional app.js and optional image.svg). '
          'Each file value must be complete UTF-8 source, at most 64000 bytes; '
          'the entire JSON must be at most 128000 bytes. No Markdown fences, '
          'commands, dependencies, remote resources or additional files. Use image.svg for one local SVG image when needed; reference it from HTML/CSS. '
          'Use semantic HTML, responsive maintainable CSS, keyboard focus '
          'states and local interactions appropriate to the instruction. '
          'Source will require separate review and validation before use. '
          'Instruction: ${jsonEncode(instruction)}';
      final buffer = StringBuffer();
      await for (final chunk in provider.generate(prompt)) {
        if (_cancelled) throw StateError('HTML source proposal cancelled.');
        // A code-unit bound avoids encoding an arbitrarily large chunk.
        if (buffer.length + chunk.length > HtmlSourceProposal.maxResponse) {
          throw const FormatException('HTML proposal response is too large.');
        }
        buffer.write(chunk);
      }
      if (_cancelled) throw StateError('HTML source proposal cancelled.');
      result = HtmlSourceProposal.decode(buffer.toString());
    } finally {
      try {
        await _provider?.cancel();
      } finally {
        _provider = null;
        _active = false;
      }
    }
    if (_cancelled) throw StateError('HTML source proposal cancelled.');
    return result;
  }

  Future<void> cancel() async {
    if (!_active) return;
    _cancelled = true;
    await _provider?.cancel();
  }
}
