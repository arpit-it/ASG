// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../models/historical_model_observation.dart';

/// Reads only the exact reviewed bundled report. No network or live matching.
class HistoricalModelObservationStore {
  HistoricalModelObservationStore({Future<String> Function()? read})
    : _read = read ?? (() => rootBundle.loadString(asset, cache: false));
  final Future<String> Function() _read;
  static const asset =
      'docs/development/acceptance/2026-11-10-live-27b-profile/observations.json';
  static const digest =
      'eee33435396d9bbb962012979a71c4180329d8e20dbe6517ef40d55647a4570f';

  Future<HistoricalModelObservation> load() async {
    try {
      final text = await _read();
      // Pin every byte, including provenance and unrendered scope limitations.
      // A new report requires deliberate code review, never an arbitrary import.
      if (text.length > 16384 ||
          sha256.convert(utf8.encode(text)).toString() != digest) {
        throw const FormatException();
      }
      final json = jsonDecode(text) as Map<String, dynamic>;
      final checks = json['checks'] as Map<String, dynamic>;
      final runs = <HistoricalModelRun>[];
      for (final entry in const {
        'json': 'JSON',
        'structured_sse': 'Structured SSE',
        'retry': 'Retry',
      }.entries) {
        final metrics = checks[entry.key]['metrics'] as Map<String, dynamic>;
        runs.add(
          HistoricalModelRun(
            label: entry.value,
            promptTokens: metrics['prompt_tokens'] as int,
            completionTokens: metrics['completion_tokens'] as int,
            tokensPerSecond: (metrics['tokens_per_second'] as num).toDouble(),
            processPeakGb: (metrics['peak_memory_gb'] as num).toDouble(),
          ),
        );
      }
      return HistoricalModelObservation(
        recordedAt: DateTime.parse(json['recorded_at'] as String),
        sourceRevision: json['source_revision'] as String,
        runs: List.unmodifiable(runs),
        disconnectSeconds: (checks['disconnect']['idle_seconds'] as num)
            .toDouble(),
        weightBytes: json['weights']['disk_bytes'] as int,
      );
    } catch (_) {
      throw const FormatException(
        'Historical observation unavailable. Retry loading the bundled report.',
      );
    }
  }
}
