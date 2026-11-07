// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

enum CandidateTextState { text, absent, unsupported, byteLimit, lineLimit }

class CandidateTextSide {
  const CandidateTextSide._(this.state, this.text);
  final CandidateTextState state;
  final String? text;

  static CandidateTextSide _decode(Object? raw) {
    const invalid = FormatException('Invalid candidate file review.');
    if (raw is! Map<String, dynamic> ||
        raw.length != 2 ||
        raw['state'] is! String ||
        !raw.containsKey('text')) {
      throw invalid;
    }
    final state = CandidateTextState.values
        .where((s) => s.name == raw['state'])
        .firstOrNull;
    if (state == null) throw invalid;
    final text = raw['text'];
    if (state != CandidateTextState.text) {
      if (text != null) throw invalid;
      return CandidateTextSide._(state, null);
    }
    if (text is! String ||
        utf8.decode(utf8.encode(text)) != text ||
        utf8.encode(text).length > 16384 ||
        text.runes.any(
          (r) => (r < 32 && !{9, 10, 13}.contains(r)) || (r >= 127 && r <= 159),
        )) {
      throw invalid;
    }
    final lines = text.isEmpty
        ? 0
        : text.split(RegExp(r'\r\n|[\r\n\u2028\u2029]')).length -
              (RegExp(r'(\r\n|[\r\n\u2028\u2029])$').hasMatch(text) ? 1 : 0);
    if (lines > 500) throw invalid;
    return CandidateTextSide._(state, text);
  }
}

/// Complete bounded text sampled under one selected candidate fingerprint.
class CandidateFileReview {
  const CandidateFileReview._(
    this.commit,
    this.digest,
    this.path,
    this.before,
    this.after,
  );
  final String commit, digest, path;
  final CandidateTextSide before, after;

  factory CandidateFileReview.decode(String source) {
    const invalid = FormatException('Invalid candidate file review.');
    try {
      if (source.length > 131072) throw invalid;
      final raw = jsonDecode(source);
      if (raw is! Map<String, dynamic> ||
          raw.length != 6 ||
          raw['schemaVersion'] is! int ||
          raw['schemaVersion'] != 1 ||
          raw['commit'] is! String ||
          raw['digest'] is! String ||
          raw['path'] is! String ||
          !RegExp(r'^[a-f0-9]{40}$').hasMatch(raw['commit'] as String) ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(raw['digest'] as String)) {
        throw invalid;
      }
      final path = raw['path'] as String;
      final parts = path.split('/');
      if (parts.length > 16 ||
          parts.any(
            (p) =>
                !RegExp(r'^[A-Za-z0-9_. @-]{1,100}$').hasMatch(p) ||
                {'.', '..', '.git'}.contains(p.toLowerCase()),
          )) {
        throw invalid;
      }
      final before = CandidateTextSide._decode(raw['before']);
      final after = CandidateTextSide._decode(raw['after']);
      if (before.state == CandidateTextState.absent &&
          after.state == CandidateTextState.absent) {
        throw invalid;
      }
      return CandidateFileReview._(
        raw['commit'] as String,
        raw['digest'] as String,
        path,
        before,
        after,
      );
    } on Object {
      throw invalid;
    }
  }
}
